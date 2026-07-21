//
//  DevUnrestrictedWarning.swift
//  Zerro
//
//  Dev Mode — the §7 Unrestricted record-time warning. A single confirmation at
//  RECORD time (the moment that matters), shown ONLY when the active tier is
//  `.unrestricted` and the user hasn't suppressed it. The fenced tiers
//  (`.askPermission` / `.autoApprove`) never warn — they keep the agent inside the
//  project. This is separate from the Ask Permission review gate (which is
//  post-recording, pre-dispatch); Unrestricted has no review gate, only this.
//
//  The decision logic is split into PURE functions (`shouldShow` /
//  `shouldSuppressAfter`) so the gate is unit-testable without any UI; only
//  `runModal()` touches AppKit.
//

import AppKit

enum DevUnrestrictedWarning {

    // MARK: - Pure decision logic (testable without UI)

    /// Should the record-time warning be shown? Only the `.unrestricted` tier
    /// triggers it, and only until the user suppresses it (then it never shows).
    /// Fires EVERY record while unsuppressed — there is no "already confirmed once"
    /// state. The fenced tiers always return `false`.
    static func shouldShow(tier: DevPermissionTier, suppressed: Bool) -> Bool {
        tier == .unrestricted && !suppressed
    }

    /// The user's response to the warning dialog.
    struct Decision: Equatable {
        /// `true` ⇒ start the recording in Unrestricted; `false` ⇒ abort (Cancel).
        let proceed: Bool
        /// Whether "Don't show this warning again" was checked.
        let dontShowAgain: Bool

        /// The safe outcome (abort, no suppression) — used as the default/teardown.
        static let cancel = Decision(proceed: false, dontShowAgain: false)
    }

    /// Should the suppression flag be persisted after `decision`? ONLY when the user
    /// PROCEEDS with the checkbox checked — a checked box is ignored on Cancel (§7).
    static func shouldSuppressAfter(_ decision: Decision) -> Bool {
        decision.proceed && decision.dontShowAgain
    }

    // MARK: - Copy (§7)

    static let title = "Run in Unrestricted mode?"
    static let body = """
        Unrestricted mode lets the agent do anything on your computer: run any \
        command, access the internet, and make changes outside this project, \
        including to databases, deployments, and files Zerro cannot undo. Only \
        continue if you fully trust the agent with this task. (Ask Permission and \
        Auto-Approve keep the agent inside this project, where changes can be \
        reverted.)
        """
    static let proceedButtonTitle = "Proceed in Unrestricted"
    static let cancelButtonTitle = "Cancel"
    static let suppressionTitle = "Don't show this warning again"

    // MARK: - Presentation (AppKit — the app's confirmation idiom)

    /// Presents the warning as an app-modal `NSAlert` (matching the app's existing
    /// confirmation style — `NSAlert` + `runModal()`, here with a suppression
    /// checkbox) and returns the user's `Decision`. Cancel is the default/safe
    /// button: both Return and Escape cancel, so a dangerous run never fires on a
    /// stray keypress — Proceed requires an explicit click. Main-actor only.
    @MainActor
    static func runModal() -> Decision {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        // Proceed is the FIRST button (rightmost, the affirmative slot) but NOT the
        // default; Cancel (second) is made the default via its Return key
        // equivalent. Escape auto-maps to the "Cancel"-titled button.
        let proceed = alert.addButton(withTitle: proceedButtonTitle)
        let cancel = alert.addButton(withTitle: cancelButtonTitle)
        proceed.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = suppressionTitle

        let response = alert.runModal()
        return Decision(
            proceed: response == .alertFirstButtonReturn,
            dontShowAgain: alert.suppressionButton?.state == .on
        )
    }
}
