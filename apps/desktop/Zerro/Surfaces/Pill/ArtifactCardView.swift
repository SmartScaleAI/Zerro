//
//  ArtifactCardView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/12/26.
//
//  The ENTIRE expanded result view (UI revision 2): the old outer container
//  (strip + gutters) is gone — this card IS the expanded pill, drawn on the
//  pill chrome itself (the chrome's vfPillBackground + hairline is the card
//  surface; this view adds no background of its own). One container, top to
//  bottom:
//
//    1. header — green check badge + dynamic title (artifact) or
//       "Response ready" (chat-only) left; "Hide ⌃" + hairline divider +
//       close X right (the pre-refactor header's divider + gray-circle
//       hover treatment).
//    2. chat text — the conversational summary as prose (ChatProseText),
//       sitting visually on top of the prompt box below it.
//    3. body well — the dark inner prompt container (artifact only):
//       monospace for `snippet`, markdown otherwise.
//    4. footer — credits charge line bottom-left; the per-type copy capsule
//       (artifact) or the ghost "✎ Write agent prompt" button (chat-only)
//       bottom-right.
//
//  Pure renderer: everything it shows arrives via props, every effect
//  leaves via a closure. Copy payloads live upstream in
//  `AppState.resultCopyPayload`; this view only fires `onCopy`.
//

import SwiftUI

struct ArtifactCardView: View {
    /// nil → the chat-only layout (no body well, ghost convert button in
    /// the footer).
    let artifact: Artifact?
    /// Conversational summary above the prompt box. May be empty when the
    /// model led straight into the artifact.
    let chatText: String
    /// "−N credits · M left" (Managed results); nil leaves the footer's
    /// left side empty (BYOK/local).
    let chargeLine: String?
    /// Amber heads-up: the result was generated from the screen alone.
    let noNarration: Bool
    /// Neutral heads-up: recovered from a sleep-interrupted recording.
    let stoppedBySleep: Bool
    /// Phase 6 — the "Write agent prompt" affordance state (chat-only).
    let conversion: ConversionAffordance
    /// Writes the per-type payload to the clipboard (wired to
    /// `AppState.resultCopyPayload` via the pill's onCopy).
    let onCopy: () -> Void
    /// The header's Hide chevron — collapses to the compact capsule.
    let onCollapse: () -> Void
    /// The header's close X — dismisses the result (AppState.resetToIdle).
    let onDismiss: () -> Void
    /// Phase 6 — starts (or retries) the conversion.
    let onConvert: () -> Void

    /// When non-nil, the card renders in its FAILURE configuration (the
    /// "show generation failures in the expanded response card" handoff): the
    /// green check badge becomes the amber caution icon, the title reads
    /// "Generation failed", the body shows the underlying error as prose, and
    /// the footer Copy button is replaced with Retry. All success-only chrome
    /// (chat text, body well, conversion affordance, charge line, notes) is
    /// suppressed. nil → the normal success card. Defaulted so the success
    /// call site (ResultPillContent) is unchanged.
    var failure: FailureConfig? = nil
    /// Fires the Retry action in the failure configuration (wired to
    /// `AppState.retryFailedPrompt` via the pill's `onRetryError`). Inert in
    /// the success configuration. Defaulted for the success call site.
    var onRetry: () -> Void = {}

    /// When non-nil, the card renders in its DEV-RESULT configuration (the Dev
    /// Mode result-card handoff): green success badge + a fixed title, the
    /// agent's human-readable summary in the text region, the readable git diff
    /// in the body well (monospace), and a destructive "Undo" + green "Accept"
    /// pair in the footer (the Copy slot). The X dismiss + Hide/expand chrome are
    /// kept; the success-only chat text, conversion affordance, and copy are
    /// suppressed — exactly as `failure` suppresses them. The charge line is NOT
    /// suppressed (managed Dev Mode meters its prompt generation like artifact
    /// mode), so it still renders bottom-left from the shared `chargeLine`. nil → the normal card.
    /// Mutually exclusive with `failure`. Defaulted so existing call sites are
    /// unchanged.
    var devResult: DevResultConfig? = nil
    /// Fires the dev-result "Undo" action (wired to `AppState.revertDevDispatch`
    /// via the pill's `onDevRevert`). Inert outside the dev-result configuration.
    var onUndo: () -> Void = {}

    /// The failure card's content + footer. The two strings (the short bold
    /// `headline` and the wrapped `detail` prose) are shared by every error-
    /// family pill; the optional button config lets the SAME card render
    /// `.failureExpanded`'s lone Retry, `.error`'s Cancel + Retry pair, and
    /// `.paidBlockResume`'s Discard + Upgrade/Generate pair. Not `Equatable`
    /// (it carries action closures); never compared.
    struct FailureConfig {
        let headline: String
        let detail: String
        /// Quiet left button (Cancel / Discard). nil → no secondary (the
        /// `.failureExpanded` card keeps its header-X-only treatment).
        var secondaryTitle: String? = nil
        var onSecondary: (() -> Void)? = nil
        /// Filled right button. Defaults to the existing amber Retry; its
        /// action is the card's `onRetry` closure.
        var primaryTitle: String = "Retry"
        var primaryIcon: String? = "arrow.clockwise"
        var primaryRole: PillPrimaryButton.Role = .warning
        /// Leading badge tint + glyph. Defaults to the amber caution every
        /// failure card shows; the entitled `.paidBlockResume` overrides them to
        /// a blue checkmark ("you're all set" confirmation).
        var badgeTint: Color = .vfWarningAmber
        var badgeSymbol: String = "exclamationmark.triangle.fill"
        /// Forces the header `×` dismiss to stay even when a secondary button is
        /// present. By default a secondary (Cancel / Discard) IS the dismiss, so
        /// the header X is dropped to avoid two close affordances. `.devFailed`
        /// sets this: its secondary (Revert — restore files) is NOT the same as
        /// dismiss (keep the partial edits and close), so both must show.
        var keepsDismiss: Bool = false
    }

    /// What the dev-result card renders: the fixed header `title`, the
    /// human-readable `summary` (agent text or a generated fallback, decided
    /// upstream), and the readable, pre-capped unified `diffText`.
    struct DevResultConfig: Equatable {
        let title: String
        let summary: String
        let diffText: String
    }

    /// Transient "Copied" confirmation — same pattern and timing as the
    /// compact header's copy button: flips on tap, reverts after 1.6s, a
    /// re-tap restarts the window.
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private static let copyFeedbackDuration: Duration = .seconds(1.6)

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            header
            if let failure {
                // Failure configuration: the underlying error as prose, no
                // success-only chrome.
                failureBody(failure)
            } else if let devResult {
                // Dev-result configuration: the human summary above the readable
                // git diff. No other success-only chrome.
                devResultBody(devResult)
            } else {
                if stoppedBySleep {
                    stoppedBySleepNote
                }
                if noNarration {
                    noNarrationNote
                }
                if !chatText.isEmpty {
                    chatSection
                }
                if let artifact {
                    bodyWell(for: artifact)
                }
                if artifact == nil, conversion == .failed {
                    conversionFailureNote
                }
            }
            footer
        }
        .padding(VFSpacing.lg)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: VFSpacing.sm + 2) {
            badge

            // The model-written title (§2 caps it at 80 chars; an over-long
            // one that slipped past the warning truncates here). Chat-only
            // shares the compact capsule's neutral label; failure mode shows
            // the fixed "Generation failed" headline.
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: VFSpacing.xxl)

            HStack(spacing: VFSpacing.md) {
                // The failure card has no compact form, so it omits the
                // Hide/collapse chevron — only Dismiss remains.
                if failure == nil {
                    collapseToggle
                }
                // The dev-result card drops the header X (Undo/Accept in the
                // footer are the terminal actions). Everything else keeps the
                // divider + X: the normal success card, and the secondary-less
                // `.failureExpanded` (a secondary in the footer already dismisses).
                if devResult == nil {
                    if failure == nil {
                        dismissDivider
                    }
                    // Show the header X when there's no secondary acting as the
                    // dismiss, OR when the card explicitly keeps it (`.devFailed`,
                    // where Revert ≠ keep-and-close).
                    if failure?.secondaryTitle == nil || failure?.keepsDismiss == true {
                        PillDismissButton(action: onDismiss)
                    }
                }
            }
        }
    }

    /// The header glyph: the green check in success, and in failure the config's
    /// badge (amber caution by default, blue checkmark for the entitled
    /// "you're all set" pill) — the canonical `PillLeadingIconBadge` either way,
    /// so every indicator reads at the same weight.
    @ViewBuilder
    private var badge: some View {
        if let failure {
            PillLeadingIconBadge(systemImage: failure.badgeSymbol, tint: failure.badgeTint)
        } else {
            PillLeadingIconBadge(systemImage: "checkmark", tint: .vfSuccessGreen)
        }
    }

    private var title: String {
        if let failure { return failure.headline }
        if let devResult { return devResult.title }
        guard let artifact else { return "Response ready" }
        return artifact.title.isEmpty ? "Untitled" : artifact.title
    }

    private var collapseToggle: some View {
        Button(action: onCollapse) {
            HStack(spacing: 4) {
                // "Hide changes" on the dev-result card, symmetric with the
                // collapsed pill's "View changes"; plain "Hide" elsewhere.
                Text(devResult != nil ? "Hide changes" : "Hide")
                    .font(.system(size: 12))
                    .fixedSize()
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.vfTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// Thin vertical hairline between the Hide toggle and the close X —
    /// visually groups dismiss as a separate affordance from
    /// expand/collapse. Always visible (pre-refactor header treatment).
    private var dismissDivider: some View {
        Rectangle()
            .fill(Color.vfHairline)
            .frame(width: 1, height: 20)
    }

    // MARK: Chat text

    /// The summary, directly below the header and above the prompt box.
    /// Hugs short chat and scrolls long chat: with a body well below, the
    /// cap is tight (the chat is the intro, the prompt is the payload);
    /// chat-only gets the room the old body had.
    private var chatSection: some View {
        HeightCappedScroll(maxHeight: artifact == nil ? 420 : 160, fadesScrollEdges: true) {
            ChatProseText(text: chatText)
        }
    }

    // MARK: Body well

    /// The darker inner well the prompt text sits in — the card's deepest
    /// layer, near-black over the chrome.
    private func bodyWell(for artifact: Artifact) -> some View {
        HeightCappedScroll(maxHeight: 320) {
            Group {
                if artifact.type.rendersMonospace {
                    // snippet — exact text, code voice. (agent_prompt is
                    // "mono-leaning" via HighlightedMarkdownView's own
                    // monospaced base font, not this branch.)
                    Text(artifact.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.vfTextPrimary)
                        .textSelection(.enabled)
                } else {
                    HighlightedMarkdownView(markdown: artifact.body)
                }
            }
            .padding(VFSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .clipShape(RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: VFSpacing.md) {
            // The charge line is a success-only readout — suppressed in the
            // failure configuration, but shown for the dev-result card too
            // (managed Dev Mode meters its prompt generation just like artifact
            // mode). `.devFailed` routes through `failure`, so it's still hidden
            // there.
            if let chargeLine, failure == nil {
                Text(chargeLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextSecondary)
                    .fixedSize()
            }
            Spacer(minLength: VFSpacing.md)
            if let failure {
                failureFooter(failure)
            } else if devResult != nil {
                // Secondary-left / primary-right, like the rest of the card
                // chrome: destructive Undo, then the green Accept CTA rightmost.
                undoButton
                acceptButton
            } else if artifact != nil {
                copyButton
            } else if conversion != .hidden {
                conversionButton
            }
        }
    }

    // MARK: Failure configuration

    /// The underlying error rendered as prose, reusing the chat-text scroll so
    /// a long error wraps and scrolls instead of overflowing the card.
    private func failureBody(_ failure: FailureConfig) -> some View {
        HeightCappedScroll(maxHeight: 420, fadesScrollEdges: true) {
            ChatProseText(text: failure.detail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The failure card's footer: an optional quiet secondary (Cancel / Discard)
    /// plus the configurable filled primary (Retry / Upgrade / Generate). The
    /// primary's action is always `onRetry` — the single primary-action closure
    /// the call site wires per state. `.failureExpanded` passes no secondary, so
    /// this collapses to the lone amber Retry it rendered before.
    @ViewBuilder
    private func failureFooter(_ failure: FailureConfig) -> some View {
        if let secondaryTitle = failure.secondaryTitle, let onSecondary = failure.onSecondary {
            PillSecondaryButton(title: secondaryTitle, action: onSecondary)
        }
        PillPrimaryButton(
            title: failure.primaryTitle,
            systemImage: failure.primaryIcon,
            role: failure.primaryRole,
            action: onRetry
        )
    }

    // MARK: Dev-result configuration

    /// The human-readable summary above the readable git diff. The summary reuses
    /// the chat-prose voice (markdown-rendered, capped + scrollable); the diff
    /// sits in the same dark well the artifact body uses, monospace.
    @ViewBuilder
    private func devResultBody(_ dev: DevResultConfig) -> some View {
        if !dev.summary.isEmpty {
            HeightCappedScroll(maxHeight: 160, fadesScrollEdges: true) {
                ChatProseText(text: dev.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        devDiffWell(dev.diffText)
    }

    /// The diff body well — the same near-black inner container the artifact body
    /// uses, holding the unified diff in a monospace, lightly colorized voice
    /// (added/removed/hunk lines tinted). Selectable; empty diffs read as a
    /// neutral placeholder.
    private func devDiffWell(_ diffText: String) -> some View {
        HeightCappedScroll(maxHeight: 320, fadesScrollEdges: true) {
            Group {
                if diffText.isEmpty {
                    Text("No tracked-file changes.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.vfTextSecondary)
                } else {
                    Text(Self.colorizedDiff(diffText))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(VFSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .clipShape(RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous))
    }

    /// Build an `AttributedString` that tints each diff line by its kind while
    /// keeping the whole thing one selectable `Text` (per-line `Text` views would
    /// break cross-line selection). Only the foreground color is set here — the
    /// uniform monospaced font comes from the `Text`'s `.font` modifier.
    private static func colorizedDiff(_ diff: String) -> AttributedString {
        var out = AttributedString()
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(String(line))
            piece.foregroundColor = diffLineColor(line)
            out += piece
            if index < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    /// Map a diff line to its tint. File/index headers and `---`/`+++` markers
    /// read as secondary; hunk headers accent; added lines green, removed red;
    /// context lines primary. Order matters: the `+++`/`---` markers are checked
    /// before the generic `+`/`-` added/removed rules.
    private static func diffLineColor(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .vfTextSecondary }
        if line.hasPrefix("@@") { return .vfAccentBlue }
        if line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ") { return .vfTextSecondary }
        if line.hasPrefix("+") { return .vfSuccessGreen }
        if line.hasPrefix("-") { return .vfRecordingRed }
        return .vfTextPrimary
    }

    /// The dev-result footer's destructive Undo + green Accept — the SAME shared
    /// `DevUndoButton` / `DevAcceptButton` the collapsed summary pill renders, so
    /// the two forms can't drift. Undo reverts; Accept keeps the changes and
    /// closes (`onDismiss`, the same close-and-keep the card's chrome uses).
    private var undoButton: some View { DevUndoButton(action: onUndo) }
    private var acceptButton: some View { DevAcceptButton(action: onDismiss) }

    /// The hero Copy action. At rest it's the `.positive` primary; on tap it
    /// flips to a transient green "Copied" confirmation (same capsule footprint,
    /// still tappable so a re-tap restarts the window) before reverting.
    @ViewBuilder
    private var copyButton: some View {
        if didCopy {
            Button(action: handleCopy) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copied")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize()
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, PillMetrics.primaryHPad)
                .padding(.vertical, PillMetrics.primaryVPad)
                .background(Color.vfSuccessGreen, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .animation(.easeInOut(duration: 0.15), value: didCopy)
        } else {
            PillPrimaryButton(
                title: artifact?.type.buttonLabel ?? "Copy",
                systemImage: "doc.on.doc",
                role: .positive,
                action: handleCopy
            )
            .animation(.easeInOut(duration: 0.15), value: didCopy)
        }
    }

    private func handleCopy() {
        onCopy()
        Analytics.capture("artifact_copied", [
            "artifact_type": artifact?.type.rawValue ?? "chat"
        ])
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: Self.copyFeedbackDuration)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    // MARK: Conversion (chat-only footer)

    /// Phase 6 — the ghost "✎ Write agent prompt" affordance: a quiet
    /// stroked capsule (deliberately NOT the hero copy style) with an
    /// inline spinner while the conversion runs. The failure note renders
    /// above the footer; the existing chat text is never touched.
    private var conversionButton: some View {
        Button(action: onConvert) {
            HStack(spacing: 6) {
                if conversion == .running {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.vfTextSecondary)
                    Text("Writing prompt\u{2026}")
                        .fixedSize()
                } else {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11, weight: .medium))
                    Text("Write agent prompt")
                        .fixedSize()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vfTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(conversion == .running)
    }

    private var conversionFailureNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfWarningAmber)
            Text("Couldn\u{2019}t write the prompt \u{2014} try again")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize()
        }
    }

    // MARK: Notes

    /// Amber heads-up shown above the chat text when no usable narration
    /// was detected. Explains why the result reads generically (generated
    /// from the screen alone) without framing it as a failure.
    private var noNarrationNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfWarningAmber)
            Text("No narration detected \u{2014} this prompt was generated from your screen alone. For a sharper result, record again and describe what you want.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// M2 — neutral heads-up when this result was recovered at launch from
    /// a recording a system sleep interrupted. Not a quality caveat: it
    /// only explains why a result appeared on its own.
    private var stoppedBySleepNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "moon.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
            Text("Recovered from a recording that stopped when your Mac went to sleep \u{2014} this prompt was built from what you captured before then.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - HeightCappedScroll
//
// A ScrollView that hugs its content's height up to `maxHeight`, then
// scrolls. Plain `ScrollView` can't do this: its ideal height is its
// content's full intrinsic height, so a fixed `.frame(height:)` either
// over-allocates short content (a one-line snippet floating in 300pt of
// card) or requires knowing the content height up front. Measuring via
// `onGeometryChange` and clamping gives short bodies a snug card and long
// ones an internal scroll. The pill window re-fits itself when the
// measured height lands (see PillWindowController's content-size
// observation).

struct HeightCappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    /// When true, the scroll view fades its top/bottom edges while there is
    /// off-screen content in that direction — a "scroll shadow" cue that the
    /// capped text is overflowing. Position-aware: the top fade appears only
    /// once scrolled away from the top, the bottom fade only while more sits
    /// below, so a snug (non-overflowing) body shows no fade at all.
    var fadesScrollEdges: Bool = false
    @ViewBuilder let content: Content

    /// Measured content height; starts at 0 (the view renders effectively
    /// collapsed for the first layout pass, then snaps to the measurement
    /// before draw).
    @State private var contentHeight: CGFloat = 0

    /// Which edges currently have more content beyond them. Both `true`
    /// (nothing to scroll) → no fade.
    @State private var edges = ScrollEdges(atTop: true, atBottom: true)

    private var scrollHeight: CGFloat { min(max(contentHeight, 1), maxHeight) }

    var body: some View {
        let scroll = ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .frame(height: scrollHeight)

        if fadesScrollEdges {
            scroll
                .onScrollGeometryChange(for: ScrollEdges.self) { geo in
                    ScrollEdges(
                        atTop: geo.contentOffset.y <= geo.contentInsets.top + 0.5,
                        atBottom: geo.contentOffset.y + geo.containerSize.height
                            >= geo.contentSize.height - 0.5
                    )
                } action: { _, newValue in
                    edges = newValue
                }
                .mask(edgeFadeMask)
        } else {
            scroll
        }
    }

    /// A vertical gradient mask: opaque through the middle, fading to clear
    /// over `fade` points at whichever edge still has content beyond it.
    private var edgeFadeMask: some View {
        let fade: CGFloat = 18
        let h = max(scrollHeight, 1)
        let topLoc = edges.atTop ? 0 : min(0.5, fade / h)
        let bottomLoc = edges.atBottom ? 1 : max(0.5, 1 - fade / h)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black, location: topLoc),
                .init(color: .black, location: bottomLoc),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Whether a capped scroll view is pinned to its top/bottom edge — drives the
/// `HeightCappedScroll` edge-fade cue.
private struct ScrollEdges: Equatable {
    var atTop: Bool
    var atBottom: Bool
}

// MARK: - ChatProseText
//
// The conversational chat text. PROSE, not code: standard UI font, normal
// line spacing — it must read like a sentence addressed to the user, not a
// terminal dump (the body well keeps the monospace voice). Full block
// markdown renders here via ProseMarkdownView — headings, bullet/numbered
// lists, and tables lay out as structure instead of leaking through as
// literal `###` / `|---|` / `- ` syntax — and inline markdown (`code`,
// *emphasis*, **bold**) resolves within each block. The artifact body well
// is intentionally NOT routed through this; it stays raw/monospace.

struct ChatProseText: View {
    let text: String

    var body: some View {
        ProseMarkdownView(markdown: text)
    }
}

// MARK: - Previews

/// Focused dev-result footer: destructive "Undo" (left) + green "Accept" (right).
/// Hover the Undo to see the faint red capsule; the full-pill variants live in
/// PillView's "Dev result" previews.
#Preview("Artifact card · Dev result") {
    ArtifactCardView(
        artifact: nil,
        chatText: "",
        chargeLine: nil,
        noNarration: false,
        stoppedBySleep: false,
        conversion: .hidden,
        onCopy: {},
        onCollapse: {},
        onDismiss: {},
        onConvert: {},
        devResult: ArtifactCardView.DevResultConfig(
            title: "Changes applied",
            summary: "Recolored the primary button and tightened the header spacing.",
            diffText: """
            diff --git a/App.css b/App.css
            @@ -1,3 +1,3 @@
            -.btn { color: blue; }
            +.btn { color: teal; }
            """
        ),
        onUndo: {}
    )
    .frame(width: 420)
    .padding()
}
