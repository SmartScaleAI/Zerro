//
//  ModelSpec.swift
//  Zerro
//
//  The immutable description of a downloadable on-device model: WHICH file to
//  fetch, from WHERE, and how to VERIFY it. This is the single source of truth
//  for a model's identity + integrity, shared by:
//    • `WhisperCppTranscriptionService.ProductionModel.spec` — the production
//      default (the ~547 MB large-v3-turbo-q5_0 weights).
//    • `LocalModelManager` — downloads + verifies against it.
//  Tests construct their own spec pointing at a small `file://` fixture (with its
//  own real checksum/size) so they never touch the production download.
//

import CryptoKit
import Foundation

nonisolated struct ModelSpec: Sendable, Equatable {
    /// Stable model id — the ggml file's base name without extension. Also the
    /// value persisted as `PreferencesStore.localModelVersion` once installed.
    let id: String
    /// File name the model is stored under in the models directory.
    let fileName: String
    /// Where the file is fetched from (`https` in production, `file://` in tests).
    let sourceURL: URL
    /// Expected SHA-256 of the file, lowercase hex.
    let sha256: String
    /// Expected exact byte size, in bytes.
    let byteSize: Int

    init(id: String, fileName: String, sourceURL: URL, sha256: String, byteSize: Int) {
        self.id = id
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.byteSize = byteSize
    }

    /// Reusable integrity check: `true` iff a file exists at `url`, is EXACTLY
    /// `byteSize` bytes, AND its SHA-256 equals `sha256`. The size check is a
    /// cheap fast-fail before the (heavy) hash.
    ///
    /// For the ~547 MB production model this hashes the whole file, so call it
    /// off the main actor. It's `nonisolated`, so any context can.
    func matches(fileAt url: URL, fileManager: FileManager = .default) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size == byteSize else {
            return false
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hex == sha256
    }
}
