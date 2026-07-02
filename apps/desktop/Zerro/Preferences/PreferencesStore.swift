//
//  PreferencesStore.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Single source of truth for app preferences.
//
//  Storage layout
//  --------------
//  • UserDefaults  — non-sensitive prefs (e.g. selected microphone unique ID).
//                    Read/written via this store; views never reach into
//                    `UserDefaults.standard` directly.
//  • Keychain      — secrets (currently just the OpenAI API key). Handled
//                    by `KeychainStore` and intentionally kept *out* of
//                    UserDefaults, because @AppStorage / UserDefaults
//                    serialize to a plaintext plist on disk.
//
//  The store is `@Observable` + `@MainActor` and exposes plain stored
//  properties; SwiftUI views read them via `@Bindable`. No SwiftUI types
//  are imported here so the store stays testable in isolation.
//

import Foundation

@MainActor
@Observable
final class PreferencesStore {

    // MARK: - Keys

    /// Stringly-typed UserDefaults keys, kept in one place so they don't
    /// leak into call sites the way `@AppStorage("…")` literals tend to.
    enum Keys {
        static let microphoneDeviceID = "vf.microphone.deviceID"
        static let redactSecrets = "redactSecrets"
        static let selectedModelID = "selectedModelID"
        static let pulsingRingEnabled = "pulsingRingEnabled"
        static let devCursorEnabled = "devCursorEnabled"

        // Dev Mode (Phase 1) — the mode switch + its two remembered
        // selections. Non-sandboxed, so the project folder is persisted as a
        // plain path (no security-scoped bookmark needed).
        static let devModeEnabled = "vf.dev.modeEnabled"
        static let devProjectPath = "vf.dev.projectPath"
        static let devAgentID = "vf.dev.agentID"
        /// Phase 2 — the remembered `--model` pick PER agent (agent wire id →
        /// model_id), stored as a `[String: String]` dictionary.
        static let devModelByAgent = "vf.dev.modelByAgent"

        // Dev Mode (Phase 3) — port→folder zero-setup ("talk to localhost:3000
        // and Zerro already knows the project").
        /// `port (as String) → folder path`, the learned localhost-port→project
        /// map. `devProjectPath` stays the GLOBAL last-used fallback.
        static let devProjectByPort = "vf.dev.projectByPort"
        /// Master opt-in (default OFF) for reading the browser's localhost URL to
        /// auto-detect the project folder. Surfaced as the dev-settings menu's
        /// "Auto-Detect Project" toggle; flipping it on is the permission primer.
        /// Off → the reader never runs.
        static let devAutoDetectProject = "vf.dev.autoDetectProject"
        /// One-time: the post-denial explainer has been shown.
        static let localhostDenialNoteShown = "vf.dev.localhostDenialNoteShown"

        // Dev Mode — permission tier (the single trust dial, spec §3–§4).
        /// The Dev Mode permission tier — Ask Permission / Auto-Approve /
        /// Unrestricted. Drives the review gate AND the §5 fences. Persisted as
        /// `DevPermissionTier.rawValue`; the last-used tier is remembered.
        /// Default `.askPermission` for everyone. Surfaced in the dev-settings menu.
        static let devPermissionTier = "vf.dev.permissionTier"
        /// Legacy two-tier review-gate key (`DevPermissionMode.rawValue`,
        /// askPermission/autoApprove). Read only by the one-time migration in
        /// `init` — the two values map 1:1 onto the new tier — and no longer
        /// written.
        static let legacyDevPermissionMode = "vf.dev.permissionMode"
        /// Legacy (Phase 4 v1) review-before-apply Bool, folded into the tier
        /// (true → `.askPermission`). Read only by the one-time migration in
        /// `init`; no longer written.
        static let legacyDevReviewBeforeApply = "vf.dev.reviewBeforeApply"
        /// §7 — once the user checks "Don't show again" on the Unrestricted
        /// record-time warning AND proceeds, this Bool suppresses that warning from
        /// then on. Default `false` (warns every record until suppressed). Resettable.
        static let devUnrestrictedWarningSuppressed = "vf.dev.unrestrictedWarningSuppressed"
        /// §5c hidden safety valve — when `true`, the Seatbelt filesystem-confinement
        /// wrapper is disabled and fenced tiers spawn the agent directly (an escape
        /// hatch if a bad profile bricks Dev Mode during rollout). Default `false`
        /// ⇒ wrapper ON. No UI; read at spawn time by `DevSeatbeltSandbox` (the
        /// canonical key lives there). Resettable.
        static let devSeatbeltWrapperDisabled = DevSeatbeltSandbox.wrapperDisabledDefaultsKey
        /// §8 hidden safety valve — when `true`, the network egress filter (loopback
        /// allowlisting proxy + Seatbelt egress lockdown) is disabled and a fenced
        /// run keeps OPEN egress (the filesystem fence still applies). Default
        /// `false` ⇒ filter ON. No UI; read at spawn time by `DevNetworkProxy` (the
        /// canonical key lives there). Resettable.
        static let devNetworkFilterDisabled = DevNetworkProxy.filterDisabledDefaultsKey

        // On-device transcription (Local Whisper, Phase 2).
        /// Which STT engine the BYOK/local path uses (`STTEngine.rawValue`:
        /// auto/local/cloud). A pure preference → resettable.
        static let sttEngine = "vf.stt.engine"
        /// The model id currently installed on disk (e.g.
        /// "ggml-large-v3-turbo-q5_0"), or "" when none. Written by
        /// `LocalModelManager` after a verified install. NOT resettable — it
        /// mirrors a file that survives a settings reset (see `resettable`).
        static let localModelVersion = "vf.stt.localModelVersion"
        /// When the installed model finished downloading (`Date`), or absent.
        /// Companion to `localModelVersion`; likewise NOT resettable.
        static let localModelDownloadedAt = "vf.stt.localModelDownloadedAt"
        /// Whether the one-time first-key model-download consent prompt has been
        /// shown (Phase 5). Set on EITHER choice so the prompt never re-nags. NOT
        /// resettable — a settings reset shouldn't re-trigger the prompt (the
        /// Transcription settings section still offers a manual download).
        static let localModelPromptShown = "vf.stt.localModelPromptShown"

        /// Every UserDefaults key persisted via this store. "Reset to
        /// Defaults" in App Behavior wipes exactly this set — never the
        /// Keychain entry, never the prompt history file, never the
        /// onboarding-completion flag (those have their own destructive
        /// affordances above the reset button in Settings).
        static let resettable: [String] = [
            microphoneDeviceID,
            redactSecrets,
            selectedModelID,
            pulsingRingEnabled,
            devCursorEnabled,
            devModeEnabled,
            devProjectPath,
            devAgentID,
            devModelByAgent,
            devProjectByPort,
            devAutoDetectProject,
            localhostDenialNoteShown,
            devPermissionTier,
            legacyDevPermissionMode,
            legacyDevReviewBeforeApply,
            devUnrestrictedWarningSuppressed,
            devSeatbeltWrapperDisabled,
            devNetworkFilterDisabled,
            sttEngine,
            // NOTE: `localModelVersion` / `localModelDownloadedAt` are deliberately
            // NOT here. They track an on-disk file (~547 MB) that a settings reset
            // does not delete; wiping them would tell the app "no model" while the
            // file is still present. `LocalModelManager` reconciles them against
            // the actual file integrity, so they stay out of the reset set.
        ]
    }

    // MARK: - Backing storage

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Preferences

    /// Persisted `AVCaptureDevice.uniqueID` of the selected input device.
    /// Empty string is the sentinel for "System Default" — we never persist
    /// localized device names because they aren't stable across reconnects.
    var microphoneDeviceID: String {
        didSet { defaults.set(microphoneDeviceID, forKey: Keys.microphoneDeviceID) }
    }

    /// Phase 3 — when on (the default), each keyframe's on-device OCR pass
    /// paints opaque boxes over any detected secret AND masks it as
    /// `[REDACTED]` in the text attached to the payload. Read fresh at
    /// recording-start time (like `microphoneDeviceID`) and carried to the
    /// processing pipeline, so a Settings change applies to the next recording.
    var redactSecrets: Bool {
        didSet { defaults.set(redactSecrets, forKey: Keys.redactSecrets) }
    }

    /// Phase 6 (multi-model) — the last model the user recorded with, by
    /// registry wire id. Seeds the capture toolbar's model chip (the only
    /// model picker) and is read by the generation path, which sends it as the
    /// `model` field of `/generate`. Written back at record-start when the
    /// toolbar pick differs. Defaults to `ModelRegistry.defaultModelID` (the
    /// recommended model), and re-defaults if a persisted id ever drops out of
    /// the registry (kill-switched model), so the app never sends an id the
    /// server would 400.
    var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModelID) }
    }

    /// Whether the pulsing green screen-edge ring is drawn while a Dev Mode
    /// coding-agent run is in progress. Default ON; surfaced as the Developer
    /// settings page's only toggle. Read live by `DevRingWindowController`'s
    /// observation loop (alongside `AppState.devRingActive`) so flipping it OFF
    /// fades the ring out immediately and flipping it back ON re-shows it while
    /// the agent is still active.
    var pulsingRingEnabled: Bool {
        didSet { defaults.set(pulsingRingEnabled, forKey: Keys.pulsingRingEnabled) }
    }

    /// Whether a soft green glow is drawn under the cursor (the system cursor
    /// itself is left untouched) while a Dev Mode recording is in progress.
    /// Default ON; surfaced as the Appearance settings section's second toggle.
    /// Read live by `DevCursorWindowController`'s observation loop (alongside
    /// `AppState.devCursorActive`) so flipping it OFF fades the glow out
    /// immediately mid-recording and flipping it back ON re-applies it while the
    /// recording is still running.
    var devCursorEnabled: Bool {
        didSet { defaults.set(devCursorEnabled, forKey: Keys.devCursorEnabled) }
    }

    // MARK: - Dev Mode (Phase 1)

    /// Whether Dev Mode was last left engaged. Seeds the toolbar's mode
    /// switch so a returning user lands back in the mode they were using.
    var devModeEnabled: Bool {
        didSet { defaults.set(devModeEnabled, forKey: Keys.devModeEnabled) }
    }

    /// Last-used project folder for Dev Mode (globally remembered in v1;
    /// port-keyed in a later phase). Persisted as a path; nil when unset.
    var devProjectURL: URL? {
        didSet {
            if let path = devProjectURL?.path {
                defaults.set(path, forKey: Keys.devProjectPath)
            } else {
                defaults.removeObject(forKey: Keys.devProjectPath)
            }
        }
    }

    /// Last-used Dev Mode agent (registry wire id), or nil. Re-seeded against
    /// live detection at present time, so a since-uninstalled agent doesn't
    /// ride forward as selectable.
    var selectedAgentID: String? {
        didSet {
            if let selectedAgentID {
                defaults.set(selectedAgentID, forKey: Keys.devAgentID)
            } else {
                defaults.removeObject(forKey: Keys.devAgentID)
            }
        }
    }

    /// Phase 2 — the `--model` pick remembered PER agent (agent wire id →
    /// model_id). The Model section writes here; the dispatch path reads the
    /// resolved pick via `selectedModel(forAgent:available:)`. Persisted as a
    /// plain `[String: String]` (UserDefaults stores it natively). A remembered
    /// id that's no longer in the live list is ignored at resolution time, so a
    /// retired model never rides forward to the CLI.
    var selectedModelByAgent: [String: String] {
        didSet { defaults.set(selectedModelByAgent, forKey: Keys.devModelByAgent) }
    }

    /// The resolved `--model` id for `agentID` given its currently-`available`
    /// models (newest-first; `available.first` is rank 0 = the default). Returns
    /// the remembered pick when it's still present in the list, otherwise the
    /// newest (rank 0). `nil` only when the agent has no models at all — the
    /// caller then passes no `--model` flag (agent default). This is the single
    /// place the "default = newest, drop a retired remembered pick" rule lives.
    func selectedModel(forAgent agentID: String, available: [AgentModel]) -> String? {
        if let remembered = selectedModelByAgent[agentID],
           available.contains(where: { $0.modelID == remembered }) {
            return remembered
        }
        return available.first?.modelID
    }

    // MARK: - Dev Mode (Phase 3) — port→folder map + localhost auto-match

    /// Learned `localhost port → project folder path` map (port as String key, as
    /// UserDefaults stores natively). `devProjectURL` (above) stays the GLOBAL
    /// last-used fallback; this is the per-port memory layered over it.
    var devProjectByPort: [String: String] {
        didSet { defaults.set(devProjectByPort, forKey: Keys.devProjectByPort) }
    }

    /// The remembered project folder for `port`, or nil if none mapped.
    func projectURL(forPort port: Int) -> URL? {
        guard let path = devProjectByPort[String(port)], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Remember `url` as the project folder for `port` (learned on a Dev record or
    /// a manual folder pick while a localhost port was detected).
    func setProjectURL(_ url: URL, forPort port: Int) {
        devProjectByPort[String(port)] = url.path
    }

    /// Master opt-in (default OFF): read the browser's current localhost URL to
    /// auto-detect the project folder. Surfaced as the dev-settings menu's
    /// "Auto-Detect Project" toggle; flipping it on requests browser permission.
    /// Off → the reader never runs (byte-identical to pre-Phase-3 behavior: manual
    /// pick + global last-used).
    var devAutoDetectProject: Bool {
        didSet { defaults.set(devAutoDetectProject, forKey: Keys.devAutoDetectProject) }
    }

    /// One-time flag: the post-denial explainer has been shown.
    var hasShownLocalhostDenialNote: Bool {
        didSet { defaults.set(hasShownLocalhostDenialNote, forKey: Keys.localhostDenialNoteShown) }
    }

    // MARK: - Dev Mode — permission tier

    /// The Dev Mode permission tier — the single "how much do I trust the agent"
    /// dial (spec §2–§4). `.askPermission` (default) pauses to show the generated
    /// plan for approval before dispatch and fences the agent (no MCP + scrubbed
    /// env); `.autoApprove` runs live but stays fenced; `.unrestricted` removes the
    /// fences. Read fresh at the dispatch gate (review gate + argv + env scrub).
    var devPermissionTier: DevPermissionTier {
        didSet { defaults.set(devPermissionTier.rawValue, forKey: Keys.devPermissionTier) }
    }

    /// §7 — whether the Unrestricted record-time warning is suppressed. Set `true`
    /// only when the user checks "Don't show again" AND proceeds (a checked box is
    /// ignored on Cancel). Default `false`. Read fresh at the record-time gate.
    var devUnrestrictedWarningSuppressed: Bool {
        didSet { defaults.set(devUnrestrictedWarningSuppressed, forKey: Keys.devUnrestrictedWarningSuppressed) }
    }

    /// §5c hidden safety valve — when `true`, disables the Seatbelt
    /// filesystem-confinement wrapper so fenced tiers spawn the agent directly.
    /// Default `false` (wrapper ON). No UI surface; exposed here only so it's
    /// resettable and discoverable. The spawn path reads the same UserDefaults key
    /// directly via `DevSeatbeltSandbox.isWrapperDisabled()`.
    var devSeatbeltWrapperDisabled: Bool {
        didSet { defaults.set(devSeatbeltWrapperDisabled, forKey: Keys.devSeatbeltWrapperDisabled) }
    }

    /// §8 hidden safety valve — when `true`, disables the network egress filter so
    /// a fenced run keeps open network (the filesystem fence still applies).
    /// Default `false` (filter ON). No UI surface; exposed here only so it's
    /// resettable and discoverable. The spawn path reads the same UserDefaults key
    /// directly via `DevNetworkProxy.isFilterDisabled()`.
    var devNetworkFilterDisabled: Bool {
        didSet { defaults.set(devNetworkFilterDisabled, forKey: Keys.devNetworkFilterDisabled) }
    }

    // MARK: - On-device transcription (Local Whisper, Phase 2)

    /// Which STT engine the BYOK/local path should use. Default `.auto` (local
    /// when the model is ready, else cloud when an OpenAI key exists) — keeps the
    /// rollout non-breaking. Persisted as the raw string; resettable.
    var sttEngine: STTEngine {
        didSet { defaults.set(sttEngine.rawValue, forKey: Keys.sttEngine) }
    }

    /// The model id installed on disk (e.g. "ggml-large-v3-turbo-q5_0"), or "" when
    /// none. Written by `LocalModelManager` after a verified install and read to
    /// decide whether the local engine is available. NOT wiped by a settings reset
    /// (the file outlives it); `LocalModelManager` reconciles it against the file.
    var localModelVersion: String {
        didSet { defaults.set(localModelVersion, forKey: Keys.localModelVersion) }
    }

    /// When the installed model finished downloading, or nil. Companion to
    /// `localModelVersion`; also survives a settings reset.
    var localModelDownloadedAt: Date? {
        didSet {
            if let localModelDownloadedAt {
                defaults.set(localModelDownloadedAt, forKey: Keys.localModelDownloadedAt)
            } else {
                defaults.removeObject(forKey: Keys.localModelDownloadedAt)
            }
        }
    }

    /// Whether the one-time first-key model-download consent prompt has been shown.
    /// Default false; set true on either prompt choice so it fires at most once.
    /// Intentionally NOT reset by `resetToDefaults()` (kept out of `Keys.resettable`).
    var localModelPromptShown: Bool {
        didSet { defaults.set(localModelPromptShown, forKey: Keys.localModelPromptShown) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.microphoneDeviceID = defaults.string(forKey: Keys.microphoneDeviceID) ?? ""
        // `object(forKey:)` (not `bool(forKey:)`) so an unset key falls back to
        // the privacy-on default instead of UserDefaults' false-for-missing.
        self.redactSecrets = defaults.object(forKey: Keys.redactSecrets) as? Bool
            ?? ProcessingConfig.redactSecretsDefault
        // Validate the persisted model against the registry: an unknown or
        // since-disabled id falls back to the default rather than riding to
        // the server as a guaranteed 400.
        if let storedModel = defaults.string(forKey: Keys.selectedModelID),
           let entry = ModelRegistry.entry(id: storedModel), entry.enabled {
            self.selectedModelID = storedModel
        } else {
            self.selectedModelID = ModelRegistry.defaultModelID
        }
        // `object(forKey:)` (not `bool(forKey:)`) so an unset key falls back to
        // the ON default instead of UserDefaults' false-for-missing.
        self.pulsingRingEnabled = defaults.object(forKey: Keys.pulsingRingEnabled) as? Bool ?? true
        // `object(forKey:)` (not `bool(forKey:)`) so an unset key falls back to
        // the ON default instead of UserDefaults' false-for-missing.
        self.devCursorEnabled = defaults.object(forKey: Keys.devCursorEnabled) as? Bool ?? true
        self.devModeEnabled = defaults.bool(forKey: Keys.devModeEnabled)
        if let path = defaults.string(forKey: Keys.devProjectPath), !path.isEmpty {
            self.devProjectURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.devProjectURL = nil
        }
        self.selectedAgentID = defaults.string(forKey: Keys.devAgentID)
        self.selectedModelByAgent =
            (defaults.dictionary(forKey: Keys.devModelByAgent) as? [String: String]) ?? [:]
        self.devProjectByPort =
            (defaults.dictionary(forKey: Keys.devProjectByPort) as? [String: String]) ?? [:]
        // Default OFF: `bool(forKey:)`'s false-for-missing IS the default, so the
        // browser is never read until the user opts in via the dev-settings toggle.
        self.devAutoDetectProject = defaults.bool(forKey: Keys.devAutoDetectProject)
        self.hasShownLocalhostDenialNote = defaults.bool(forKey: Keys.localhostDenialNoteShown)
        // Default `.askPermission` for EVERYONE (spec §4) — the fenced, review-gated
        // tier is the safe starting point (changes the old `.autoApprove` default).
        // The last-used tier persists via the new key; on the first run after the
        // rename, migrate the old two-tier `devPermissionMode` (askPermission /
        // autoApprove map 1:1 — identical raw strings) and, failing that, the
        // even-older `devReviewBeforeApply` Bool (true → .askPermission).
        if let raw = defaults.string(forKey: Keys.devPermissionTier),
           let tier = DevPermissionTier(rawValue: raw) {
            self.devPermissionTier = tier
        } else if let raw = defaults.string(forKey: Keys.legacyDevPermissionMode),
                  let tier = DevPermissionTier(rawValue: raw) {
            self.devPermissionTier = tier
        } else if defaults.object(forKey: Keys.legacyDevReviewBeforeApply) != nil {
            self.devPermissionTier = defaults.bool(forKey: Keys.legacyDevReviewBeforeApply)
                ? .askPermission : .autoApprove
        } else {
            self.devPermissionTier = .askPermission
        }
        // §7 default OFF: the Unrestricted record-time warning shows every record
        // until the user checks "Don't show again". `bool(forKey:)`'s
        // false-for-missing IS the desired default.
        self.devUnrestrictedWarningSuppressed = defaults.bool(forKey: Keys.devUnrestrictedWarningSuppressed)
        // §5c default OFF (wrapper ON): `bool(forKey:)`'s false-for-missing means
        // the Seatbelt wrapper is enabled until a user explicitly flips this valve.
        self.devSeatbeltWrapperDisabled = defaults.bool(forKey: Keys.devSeatbeltWrapperDisabled)
        // §8 default OFF (filter ON): same false-for-missing default — the network
        // egress filter is enabled until a user explicitly flips this valve.
        self.devNetworkFilterDisabled = defaults.bool(forKey: Keys.devNetworkFilterDisabled)
        // STT engine: default `.auto` when unset or an unknown raw value is stored.
        if let raw = defaults.string(forKey: Keys.sttEngine), let engine = STTEngine(rawValue: raw) {
            self.sttEngine = engine
        } else {
            self.sttEngine = .auto
        }
        // Model-install tracking. Default "" / nil = "no model installed".
        self.localModelVersion = defaults.string(forKey: Keys.localModelVersion) ?? ""
        self.localModelDownloadedAt = defaults.object(forKey: Keys.localModelDownloadedAt) as? Date
        // Default false: `bool(forKey:)`'s false-for-missing IS the desired default
        // (the prompt hasn't been shown on a fresh install).
        self.localModelPromptShown = defaults.bool(forKey: Keys.localModelPromptShown)
    }

    // MARK: - Reset

    /// Wipes every UserDefaults key this store owns. Called from the App
    /// Behavior "Reset to Defaults" button. Keychain, prompt history,
    /// and onboarding-completion flag are all intentionally excluded —
    /// each has its own destructive affordance in the same Settings
    /// surface, so this button can stay narrowly-scoped to "preferences".
    func resetToDefaults() {
        for key in Keys.resettable {
            defaults.removeObject(forKey: key)
        }
        // Reload from defaults so observers see the reset value
        // immediately, even before the next launch.
        microphoneDeviceID = ""
        redactSecrets = ProcessingConfig.redactSecretsDefault
        selectedModelID = ModelRegistry.defaultModelID
        pulsingRingEnabled = true
        devCursorEnabled = true
        devModeEnabled = false
        devProjectURL = nil
        selectedAgentID = nil
        selectedModelByAgent = [:]
        devProjectByPort = [:]
        devAutoDetectProject = false
        hasShownLocalhostDenialNote = false
        devPermissionTier = .askPermission
        devUnrestrictedWarningSuppressed = false
        devSeatbeltWrapperDisabled = false
        devNetworkFilterDisabled = false
        sttEngine = .auto
        // `localModelVersion` / `localModelDownloadedAt` are intentionally left
        // untouched here — they mirror the on-disk model file, which a settings
        // reset does not delete.
    }
}
