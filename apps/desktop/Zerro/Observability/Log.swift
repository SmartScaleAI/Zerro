//
//  Log.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 13 (Part A) — unified logging.
//
//  Why
//  ---
//  Replaces every NSLog / print call in the app with `os.Logger`. Three
//  things this buys us that NSLog doesn't:
//
//  1. CATEGORY FILTERING. Console.app, `log stream`, and sysdiagnose
//     dumps can filter to `subsystem:com.cbreeding.Zerro
//     category:processing` (or any single category) — dramatically
//     better than grepping `[Processing]` out of a sea of system noise.
//  2. STRUCTURED PRIVACY. Every interpolated value carries an explicit
//     `.public` or `.private` qualifier. In RELEASE builds the OS
//     redacts `.private` values as `<private>` before another process
//     (Console.app on someone else's machine, a sysdiagnose blob a
//     user emails to support) can read them. NSLog had no such layer
//     — every formatted argument was always plaintext on disk.
//  3. SENTRY BREADCRUMB BRIDGE. `Log.breadcrumb(...)` is the explicit
//     opt-in path that ALSO ships an operational marker to Sentry, so
//     the next crash report carries the last ~30s of state transitions
//     as context. Routine Logger calls stay LOCAL ONLY — they never
//     leave the machine.
//
//  Call-site shape
//  ---------------
//      Log.state.notice("transition idle -> recording")
//      Log.processing.error("downsample failed at index \(i, privacy: .public)")
//      Log.history.error("save failed: \(error.localizedDescription, privacy: .private)")
//
//  Privacy rule for interpolated values (memorize these — it's the
//  whole point of this file):
//
//  • `.public`  — subsystem-internal identifiers with no user content:
//                 state names, error case names, durations, counts,
//                 booleans, enum descriptions, model names, integer
//                 indices, basenames of system files.
//  • `.private` — anything that could carry user content or identifying
//                 info: file paths (especially anything under
//                 `/Users/...`), transcript text, generated prompt
//                 text, API request/response bodies, error
//                 `localizedDescription` values (they often embed
//                 paths), hotkey strings the user chose, microphone
//                 device names, prompt history entries.
//
//  When in doubt, mark `.private`. The cost is invisibility in
//  someone-else's-machine logs, which is exactly what we want for
//  anything user-derived.
//
//  Privacy contract for breadcrumbs (Sentry-bound, see beforeBreadcrumb
//  in CrashReporting): the `message` parameter is `StaticString` so
//  Swift only accepts a STRING LITERAL at the call site. Interpolated
//  strings, error.localizedDescription, anything runtime — won't
//  compile. This is the same mechanical enforcement we use for
//  `CrashReporting.capture(message:)`.
//

import Foundation
import os
import Sentry

enum Log {

    // MARK: - Subsystem

    /// All Logger instances share this subsystem. Read from the bundle
    /// at first access so a future bundle-ID rename can't drift —
    /// matches what `CrashReporting.releaseName()` computes against.
    /// `nonisolated` because Logger / String are Sendable and we need
    /// to read this from background tasks, nonisolated delegates, etc.
    /// The project's `-default-isolation=MainActor` flag would otherwise
    /// pin every static to MainActor.
    nonisolated private static let subsystem: String =
        Bundle.main.bundleIdentifier ?? "com.cbreeding.Zerro"

    // MARK: - Category loggers
    //
    // One Logger per category. Categories mirror the bracketed prefixes
    // the codebase already used with NSLog ([Hotkey], [AppState], etc.)
    // so call sites translate 1:1. Adding a new subsystem? Add a new
    // static Logger here, don't reuse a loosely-related one.
    //
    // Every static is `nonisolated` — Logger is Sendable, and these need
    // to be callable from any isolation context (SCStreamDelegate's
    // nonisolated methods, background Tasks, NotificationCenter
    // callbacks, etc.). The project's `-default-isolation=MainActor`
    // build flag pins everything to MainActor by default; this is the
    // explicit opt-out.

    /// App-wide launch / quit / sweep / global setup.
    nonisolated static let appLifecycle = Logger(subsystem: subsystem, category: "appLifecycle")

    /// Global hotkey handler — fire / gate decisions / dropped events.
    nonisolated static let hotkey = Logger(subsystem: subsystem, category: "hotkey")

    /// Onboarding window open / re-open / dev-drift fallbacks.
    nonisolated static let onboarding = Logger(subsystem: subsystem, category: "onboarding")

    /// AppState state-machine transitions and ignored-transition logs.
    /// Distinct from `capture` and `processing`: this category is about
    /// the .idle/.recording/.processing/.done/.failed enum movement,
    /// not about the work those states wrap.
    nonisolated static let state = Logger(subsystem: subsystem, category: "state")

    /// Capture-side work: SCStream, AVCaptureSession, mic input,
    /// writer lifecycle. Everything in `RecordingSession`.
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")

    /// Local processing pipeline: audio export, frame extraction,
    /// manifest writes. Phase 8 ProcessingPipeline.
    nonisolated static let processing = Logger(subsystem: subsystem, category: "processing")

    /// Whisper transcription stage of the API pipeline.
    nonisolated static let transcription = Logger(subsystem: subsystem, category: "transcription")

    /// GPT-4o prompt-generation stage of the API pipeline.
    nonisolated static let promptGen = Logger(subsystem: subsystem, category: "promptGen")

    /// Typed-artifact contract telemetry (Phase 4): §2 parse outcomes on
    /// generation results — recovery-tier fires (rule names only),
    /// unknown-type coercions (the type token only), and fail-safe
    /// fallbacks. Never response content. Production visibility for the
    /// recovery rate baselined in the Phase 1 eval (~4% of flash artifacts).
    nonisolated static let artifacts = Logger(subsystem: subsystem, category: "artifacts")

    /// Per-request cost accounting (Whisper minutes + GPT tokens).
    /// Separate category so a user inspecting costs can filter to just
    /// these lines without dragging in pipeline noise.
    nonisolated static let cost = Logger(subsystem: subsystem, category: "cost")

    /// Billing / entitlement: BYOK license activation & validation against
    /// LemonSqueezy (Phase C), and entitlement transitions driven by it.
    /// SECRET-HANDLING CONTRACT for this category: the raw license key is
    /// NEVER interpolated into a log line — not even `.private`. Instance
    /// IDs, validity booleans, and the License API's key STATUS strings
    /// (`active`/`expired`/`disabled`) carry no user content and are logged
    /// `.public`; anything that could embed the key (e.g. a network
    /// error description) stays `.private`. (Trial-clock transitions keep
    /// using `Log.state`, established in Phase B.)
    nonisolated static let billing = Logger(subsystem: subsystem, category: "billing")

    /// Working-directory sweep / orphan cleanup.
    nonisolated static let cleanup = Logger(subsystem: subsystem, category: "cleanup")

    /// TCC permission status reads, monitoring, mid-session revocation.
    nonisolated static let permissions = Logger(subsystem: subsystem, category: "permissions")

    /// RecentPromptStore — history load / save / migration.
    nonisolated static let history = Logger(subsystem: subsystem, category: "history")

    /// LaunchAtLoginController — SMAppService register/unregister.
    nonisolated static let launchAtLogin = Logger(subsystem: subsystem, category: "launchAtLogin")

    /// UI surfaces (area selector, pill controller, menu-bar panel,
    /// settings windows). Catch-all for view-layer events that don't
    /// belong to a more specific category.
    nonisolated static let ui = Logger(subsystem: subsystem, category: "ui")

    /// CrashReporting bootstrap notices (DSN missing, init confirmation).
    /// Separate from the runtime Sentry SDK's own logs (which live under
    /// the SentrySDK subsystem, not ours).
    nonisolated static let crashReporting = Logger(subsystem: subsystem, category: "crashReporting")

    // MARK: - Sentry breadcrumb bridge

    /// Sentry breadcrumb categories that survive `beforeBreadcrumb` in
    /// CrashReporting. MUST stay in sync with
    /// `CrashReporting.allowedBreadcrumbCategories` — kept here as a
    /// typed enum so call sites can't accidentally pass a string that
    /// the allowlist will silently drop.
    ///
    /// These are intentionally a SMALLER set than the Logger categories
    /// above. Logger categories are about Console.app filtering (every
    /// subsystem gets one); breadcrumb categories are about what kind
    /// of operational signal is useful in a CRASH REPORT (state
    /// transitions, pipeline progress, permission changes — not every
    /// UI tick or hotkey gate decision).
    enum BreadcrumbCategory: String {
        case appLifecycle    = "appLifecycle"
        case stateMachine    = "stateMachine"
        case pipelineStage   = "pipelineStage"
        case permissionChange = "permissionChange"
    }

    /// Local enum wrapping the three breadcrumb levels we use, so call
    /// sites don't need to `import Sentry`. The whole point of the
    /// Log layer is that the rest of the app only knows about Log —
    /// keeping Sentry types out of call-site files makes those files
    /// easier to test and keeps the Sentry dependency confined.
    enum BreadcrumbLevel {
        case info, warning, error

        // `nonisolated` because the `breadcrumb(...)` entry point is
        // nonisolated (must be callable from any context) and reads
        // this. The project default would otherwise pin it to MainActor.
        fileprivate nonisolated var sentryLevel: SentryLevel {
            switch self {
            case .info:    return .info
            case .warning: return .warning
            case .error:   return .error
            }
        }
    }

    /// Emit a Sentry breadcrumb. Use SPARINGLY — breadcrumbs are the
    /// "last N events leading up to a crash" context that gets
    /// attached to every captured event. They should mark NOTABLE
    /// operational transitions (entered .recording, finished
    /// transcription, screen-recording permission revoked), NOT every
    /// log line.
    ///
    /// CALL-SITE RULES — same privacy contract as
    /// `CrashReporting.capture(message:)`:
    ///
    /// • `message` is `StaticString`. The Swift type system mechanically
    ///   prevents passing interpolated strings, error descriptions, or
    ///   anything else derived from runtime user content. Make the
    ///   literal descriptive — it becomes the human-readable line in
    ///   the breadcrumb trail attached to the next crash.
    ///
    /// • `data` is intentionally NOT exposed. `beforeBreadcrumb` in
    ///   CrashReporting clears `crumb.data` on every surviving
    ///   breadcrumb anyway as a safety net, so any data you'd attach
    ///   here would be discarded before transmission.
    ///
    /// `level` defaults to `.info`; bump to `.warning` / `.error` for
    /// breadcrumbs about a failure path.
    nonisolated static func breadcrumb(
        category: BreadcrumbCategory,
        level: BreadcrumbLevel = .info,
        message: StaticString
    ) {
        let crumb = Breadcrumb()
        crumb.category = category.rawValue
        crumb.level = level.sentryLevel
        crumb.message = "\(message)"
        crumb.type = "default"
        SentrySDK.addBreadcrumb(crumb)
    }
}
