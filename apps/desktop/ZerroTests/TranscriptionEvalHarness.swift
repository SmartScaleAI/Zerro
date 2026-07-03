//
//  TranscriptionEvalHarness.swift
//  ZerroTests
//
//  Phase 8 (Local Whisper) — a repeatable, HUMAN-RUN comparison of on-device
//  transcription (large-v3-turbo-q5_0 via `WhisperCppTranscriptionService`) vs
//  cloud (whisper-1 via `OpenAITranscriptionService`). Both eval cases are GATED
//  behind env vars, so an ordinary test run SKIPS them (XCTSkip) and CI never
//  transcribes or hits the network. They reuse the PRODUCTION services and the
//  real `DeixisResolver` — no duplicated transcription or anchoring logic.
//
//  See Scripts/README-transcription-eval.md for how to run. In short:
//    export ZERRO_WHISPER_MODEL_PATH=/path/to/ggml-large-v3-turbo-q5_0.bin
//    export OPENAI_API_KEY_DEV=sk-...            # dev key — cloud whisper-1
//    export ZERRO_STT_EVAL_DIR=/path/to/audio    # harness #5 (WER + timing)
//    export ZERRO_STT_DEVEVAL_DIR=/path/to/wdir  # harness #6 (deixis timing)
//    xcodebuild test -scheme Zerro -destination 'platform=macOS' \
//      -only-testing:ZerroTests/TranscriptionEvalHarness/testEvalTranscriptionComparison
//
//  Results land under eval-results/transcription/ (a JSON blob + a Markdown
//  scorecard), matching the eval-models.mjs / eval-results conventions. Secrets
//  are read from env and NEVER written to results.
//

import AVFoundation
import XCTest
@testable import Zerro

final class TranscriptionEvalHarness: XCTestCase {

    // MARK: - #5 Transcription comparison (local vs cloud): WER + timing

    func testEvalTranscriptionComparison() async throws {
        let dir = try envDirOrSkip("ZERRO_STT_EVAL_DIR", "a folder of audio files (optionally with <name>.ref.txt references)")
        let modelURL = try resolveModelOrSkip()
        let audioFiles = try Self.audioFiles(in: dir)
        guard !audioFiles.isEmpty else { throw XCTSkip("no audio files under \(dir.path)") }

        let localService = try WhisperCppTranscriptionService(modelURL: modelURL, model: .largeV3Turbo)

        var results: [FileResult] = []
        try await withOpenAIKeyFromEnv {
            let cloudService = OpenAITranscriptionService()
            for audio in audioFiles {
                let reference = Self.referenceText(for: audio)
                let audioDuration = Self.audioDurationSeconds(audio)

                let local = try await Self.run(
                    engine: "large-v3-turbo-q5_0",
                    service: localService, audio: audio, reference: reference, audioDuration: audioDuration
                )
                let cloud = try await Self.run(
                    engine: OpenAITranscriptionService.model,
                    service: cloudService, audio: audio, reference: reference, audioDuration: audioDuration
                )
                results.append(FileResult(
                    file: audio.lastPathComponent,
                    referencePresent: reference != nil,
                    audioDurationSeconds: audioDuration,
                    local: local, cloud: cloud
                ))
                Self.log("• \(audio.lastPathComponent): local \(Self.fmt(local.seconds))s"
                    + (local.wer.map { " (WER \(Self.pct($0)))" } ?? "")
                    + " | cloud \(Self.fmt(cloud.seconds))s"
                    + (cloud.wer.map { " (WER \(Self.pct($0)))" } ?? ""))
            }
        }

        let (jsonURL, mdURL) = try Self.writeComparison(results)
        Self.log("wrote \(results.count) file result(s):\n  \(jsonURL.path)\n  \(mdURL.path)")
        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - #6 Dev-Mode deixis timing (DTW drift vs the resolver window)

    /// For a Dev-Mode working dir, transcribe with BOTH engines (word timestamps),
    /// run the REAL `DeixisResolver` on each, and report — per referring
    /// expression — the resolver window `[phraseStart − lead, phraseEnd + trail]`
    /// and whether local vs cloud word timings drift the window/anchor enough to
    /// change what a frame would be captured at. Cursor samples aren't persisted in
    /// the manifest, so clicks come from the manifest and the cursor track from an
    /// optional `cursor.eval.json` sidecar (else empty — the window/drift analysis
    /// still holds, since the window derives from the WORD timings).
    func testEvalDevModeTiming() async throws {
        let workDir = try envDirOrSkip("ZERRO_STT_DEVEVAL_DIR", "a Dev-Mode working dir (manifest.json + audio)")
        let modelURL = try resolveModelOrSkip()

        let manifest = try RecordingManifest.read(fromWorkingDirectory: workDir)
        let audio = workDir.appendingPathComponent(manifest.audioFilename)
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw XCTSkip("audio \(manifest.audioFilename) missing under \(workDir.path)")
        }
        let clickTimes = (manifest.clicks ?? []).map(\.timestampSeconds)
        let cursorTrack = Self.loadCursorSidecar(workDir)

        let localService = try WhisperCppTranscriptionService(modelURL: modelURL, model: .largeV3Turbo)
        let localT = try await localService.transcribe(audioFileURL: audio, wordTimestamps: true)

        var cloudT: Transcript!
        try await withOpenAIKeyFromEnv {
            cloudT = try await OpenAITranscriptionService().transcribe(audioFileURL: audio, wordTimestamps: true)
        }

        let config = DeixisResolver.Config.default   // reuse the REAL window (lead 0.8 / trail 0.2)
        let localAnchors = DeixisResolver.resolve(words: localT.words, cursorTrack: cursorTrack, clickTimes: clickTimes, config: config)
        let cloudAnchors = DeixisResolver.resolve(words: cloudT.words, cursorTrack: cursorTrack, clickTimes: clickTimes, config: config)

        let rows = Self.compareAnchors(local: localAnchors, cloud: cloudAnchors, config: config)
        let (jsonURL, mdURL) = try Self.writeDevTiming(rows: rows, config: config, workDir: workDir.lastPathComponent)
        Self.log("deixis phrases compared: \(rows.count) | window [-\(config.windowLead)s, +\(config.windowTrail)s]"
            + "\n  \(jsonURL.path)\n  \(mdURL.path)")
        for r in rows where !r.windowPreserved {
            Self.log("  ⚠️ \"\(r.phrase)\": drift \(Self.fmt(r.driftSeconds))s moves the anchor OUTSIDE the other engine's window")
        }
    }

    // MARK: - One transcription run (timed)

    private struct EngineRun: Codable {
        let engine: String
        let seconds: Double
        let realtimeFactor: Double?
        let charCount: Int
        let wordCount: Int
        let wer: Double?
        let transcript: String
    }

    private struct FileResult: Codable {
        let file: String
        let referencePresent: Bool
        let audioDurationSeconds: Double?
        let local: EngineRun
        let cloud: EngineRun
    }

    private static func run(
        engine: String, service: any TranscriptionService,
        audio: URL, reference: String?, audioDuration: Double?
    ) async throws -> EngineRun {
        let clock = ContinuousClock()
        let start = clock.now
        let transcript = try await service.transcribe(audioFileURL: audio, wordTimestamps: false)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let words = normalizedWords(transcript.fullText)
        let rtf: Double? = (audioDuration != nil && seconds > 0) ? audioDuration! / seconds : nil
        return EngineRun(
            engine: engine,
            seconds: seconds,
            realtimeFactor: rtf,
            charCount: transcript.fullText.count,
            wordCount: words.count,
            wer: reference.map { wordErrorRate(reference: normalizedWords($0), hypothesis: words) },
            transcript: transcript.fullText
        )
    }

    // MARK: - WER (word-level Levenshtein / reference length)

    /// Standard WER = edit distance over word sequences ÷ reference word count.
    /// Returns 0 for an empty reference (nothing to score against).
    static func wordErrorRate(reference: [String], hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        guard !hypothesis.isEmpty else { return 1 }   // all deletions
        var prev = Array(0...hypothesis.count)
        var curr = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            curr[0] = i
            for j in 1...hypothesis.count {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return Double(prev[hypothesis.count]) / Double(reference.count)
    }

    static func normalizedWords(_ text: String) -> [String] {
        let cleaned = String(text.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : " " })
        return cleaned.split(separator: " ").map(String.init)
    }

    // MARK: - Deixis anchor comparison (#6)

    struct DeixisRow: Codable {
        let phrase: String
        let localPhraseStart: Double, localPhraseEnd: Double, localTargetSeconds: Double, localSource: String
        let cloudPhraseStart: Double, cloudPhraseEnd: Double, cloudTargetSeconds: Double, cloudSource: String
        let driftSeconds: Double            // |localTarget − cloudTarget|
        let windowPreserved: Bool           // each engine's target still lands in the other's window
        let sourceChanged: Bool             // click ↔ dwell ↔ lastKnown ↔ none differs
    }

    /// Pairs referring expressions by normalized phrase text in order (the resolver
    /// emits them in transcript order), then measures how far the local vs cloud
    /// word timings move each anchor relative to the resolver window.
    static func compareAnchors(local: [CandidateAnchor], cloud: [CandidateAnchor], config: DeixisResolver.Config) -> [DeixisRow] {
        var rows: [DeixisRow] = []
        var cloudRemaining = cloud
        for l in local {
            let key = l.phrase.lowercased()
            guard let idx = cloudRemaining.firstIndex(where: { $0.phrase.lowercased() == key }) else { continue }
            let c = cloudRemaining.remove(at: idx)
            let localWindow = (l.phraseStart - config.windowLead, l.phraseEnd + config.windowTrail)
            let cloudWindow = (c.phraseStart - config.windowLead, c.phraseEnd + config.windowTrail)
            let cloudInLocal = c.targetSeconds >= localWindow.0 && c.targetSeconds <= localWindow.1
            let localInCloud = l.targetSeconds >= cloudWindow.0 && l.targetSeconds <= cloudWindow.1
            rows.append(DeixisRow(
                phrase: l.phrase,
                localPhraseStart: l.phraseStart, localPhraseEnd: l.phraseEnd,
                localTargetSeconds: l.targetSeconds, localSource: l.source.rawValue,
                cloudPhraseStart: c.phraseStart, cloudPhraseEnd: c.phraseEnd,
                cloudTargetSeconds: c.targetSeconds, cloudSource: c.source.rawValue,
                driftSeconds: abs(l.targetSeconds - c.targetSeconds),
                windowPreserved: cloudInLocal && localInCloud,
                sourceChanged: l.source != c.source
            ))
        }
        return rows
    }

    // MARK: - Inputs

    private func envDirOrSkip(_ key: String, _ what: String) throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else {
            throw XCTSkip("set \(key) to \(what) to run this harness")
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(key)=\(url.path) does not exist")
        }
        return url
    }

    /// The production model: `ZERRO_WHISPER_MODEL_PATH` if set, else the installed
    /// model (`LocalModelManager.installedModelURL()`). Skips when neither exists.
    private func resolveModelOrSkip() throws -> URL {
        if let raw = ProcessInfo.processInfo.environment["ZERRO_WHISPER_MODEL_PATH"], !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("ZERRO_WHISPER_MODEL_PATH=\(url.path) not found")
            }
            return url
        }
        if let installed = LocalModelManager.installedModelURL() { return installed }
        throw XCTSkip("no model: set ZERRO_WHISPER_MODEL_PATH or download the model in the app first")
    }

    private static let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "caf", "aiff", "aif", "flac", "mp4"]

    private static func audioFiles(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `<name>.ref.txt` (preferred) or `<name>.txt` next to the audio.
    private static func referenceText(for audio: URL) -> String? {
        let base = audio.deletingPathExtension()
        for candidate in [base.appendingPathExtension("ref.txt"), base.appendingPathExtension("txt")] {
            if let text = try? String(contentsOf: candidate, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func audioDurationSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Optional cursor track for the deixis harness: `cursor.eval.json` in the
    /// working dir, an array of `{ x, y, seconds }` (normalized [0,1]). Absent → [].
    private static func loadCursorSidecar(_ workDir: URL) -> [CursorSample] {
        let url = workDir.appendingPathComponent("cursor.eval.json")
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([CursorSample].self, from: data) else { return [] }
        return samples
    }

    // MARK: - OpenAI key (env → Keychain, restored after)

    /// Runs `body` with `OPENAI_API_KEY_DEV` (or `OPENAI_API_KEY`) installed into
    /// the OpenAI Keychain slot the production service reads, restoring the prior
    /// value afterwards. The key is only ever in the Keychain for the run and is
    /// never written to results. Skips when no key is set.
    private func withOpenAIKeyFromEnv(_ body: () async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = (env["OPENAI_API_KEY_DEV"] ?? env["OPENAI_API_KEY"]).flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw XCTSkip("set OPENAI_API_KEY_DEV (or OPENAI_API_KEY) for the cloud whisper-1 comparison")
        }
        let slot = KeychainStore.openAIAPIKey
        let previous = slot.read()
        slot.write(key)
        defer {
            if let previous, !previous.isEmpty { slot.write(previous) } else { slot.delete() }
        }
        try await body()
    }

    // MARK: - Output (eval-results/transcription/)

    private static func outputDir() throws -> URL {
        // Locate apps/desktop from this source file, then eval-results/transcription.
        // Overridable with ZERRO_STT_EVAL_OUT.
        let base: URL
        if let raw = ProcessInfo.processInfo.environment["ZERRO_STT_EVAL_OUT"], !raw.isEmpty {
            base = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            base = URL(fileURLWithPath: #filePath)   // …/apps/desktop/ZerroTests/TranscriptionEvalHarness.swift
                .deletingLastPathComponent()          // …/ZerroTests
                .deletingLastPathComponent()          // …/apps/desktop
                .appendingPathComponent("eval-results/transcription", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    private static func writeComparison(_ results: [FileResult]) throws -> (json: URL, md: URL) {
        let dir = try outputDir()
        let name = "\(stamp())_stt-comparison"
        let jsonURL = dir.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: jsonURL)

        var md = "# Transcription comparison — local vs cloud\n\n"
        md += "_\(stamp()) UTC · large-v3-turbo-q5_0 vs whisper-1_\n\n"
        md += "| file | audio (s) | local (s) | local RTF | local WER | cloud (s) | cloud RTF | cloud WER |\n"
        md += "|---|---|---|---|---|---|---|---|\n"
        for r in results {
            md += "| \(r.file) | \(fmtOpt(r.audioDurationSeconds)) "
                + "| \(fmt(r.local.seconds)) | \(fmtOpt(r.local.realtimeFactor)) | \(pctOpt(r.local.wer)) "
                + "| \(fmt(r.cloud.seconds)) | \(fmtOpt(r.cloud.realtimeFactor)) | \(pctOpt(r.cloud.wer)) |\n"
        }
        md += "\nWER is word-level edit-distance ÷ reference words (lower is better); "
        md += "RTF = audio seconds ÷ transcription seconds (higher is faster than real-time). "
        md += "Full transcripts are in the JSON beside this file.\n"
        let mdURL = dir.appendingPathComponent("\(name).md")
        try md.data(using: .utf8)!.write(to: mdURL)
        return (jsonURL, mdURL)
    }

    private static func writeDevTiming(rows: [DeixisRow], config: DeixisResolver.Config, workDir: String) throws -> (json: URL, md: URL) {
        let dir = try outputDir()
        let name = "\(stamp())_deixis-timing"
        let jsonURL = dir.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: jsonURL)

        let broken = rows.filter { !$0.windowPreserved }.count
        var md = "# Dev-Mode deixis timing — DTW drift vs resolver window\n\n"
        md += "_\(stamp()) UTC · \(workDir) · window [phrase − \(config.windowLead)s, phrase + \(config.windowTrail)s]_\n\n"
        md += "\(rows.count) referring expression(s); **\(broken)** where drift moves the anchor outside the other engine's window.\n\n"
        md += "| phrase | local target (s) | cloud target (s) | drift (s) | window kept | source Δ |\n"
        md += "|---|---|---|---|---|---|\n"
        for r in rows {
            md += "| \(r.phrase) | \(fmt(r.localTargetSeconds)) | \(fmt(r.cloudTargetSeconds)) "
                + "| \(fmt(r.driftSeconds)) | \(r.windowPreserved ? "yes" : "**NO**") "
                + "| \(r.sourceChanged ? "\(r.localSource)→\(r.cloudSource)" : "—") |\n"
        }
        md += "\nIf \"window kept\" is NO, the local (DTW) word timing drifted far enough that the "
        md += "frame the resolver captures would differ from cloud — a sign to widen the window or gate Dev Mode to cloud.\n"
        let mdURL = dir.appendingPathComponent("\(name).md")
        try md.data(using: .utf8)!.write(to: mdURL)
        return (jsonURL, mdURL)
    }

    // MARK: - Small format helpers

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func fmtOpt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    private static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    private static func pctOpt(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    private static func log(_ s: String) { print("[stt-eval] \(s)") }
}
