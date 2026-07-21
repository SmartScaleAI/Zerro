//
//  FeedbackView.swift
//  Zerro
//
//  Created by Colin Breeding on 6/15/26.
//
//  The in-app feedback dialog (replaces the old mailto link). A two-tab surface
//  — "Report an issue" / "Share feedback" — with a multiline editor and a
//  primary "Send message" button that POSTs through `FeedbackService` to the
//  `feedback` edge function (→ Slack). Modelled on `TrialEmailCaptureView`'s
//  shape: a small `@Observable` field model with an explicit phase the UI
//  renders against (idle → sending → success → failed), reusing the app's dark
//  branding + design tokens throughout.
//
//  The signed-in account email (when known) rides along so the Slack message
//  attributes the report; when signed out it's sent as null and the dialog
//  still works. The window auto-closes ~1.2s after a successful send.
//

import SwiftUI

// MARK: - FeedbackModel

@MainActor
@Observable
final class FeedbackModel {
    enum Phase: Equatable {
        case idle
        case sending
        case success
        case failed(String)
    }

    /// Default tab is "Share feedback" per the design.
    var kind: FeedbackKind = .feedback
    var message: String = ""
    var phase: Phase = .idle

    private let service: FeedbackService

    // `nil` resolves to the real service INSIDE the (MainActor) init body — a
    // `FeedbackService()` default-argument expression would evaluate nonisolated
    // and trip MainActor isolation (same seam as SessionTokenManager).
    init(service: FeedbackService? = nil) {
        self.service = service ?? FeedbackService()
    }

    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSending: Bool { phase == .sending }
    var isSuccess: Bool { phase == .success }

    /// The send button is live only with non-empty text, and not while a send
    /// is in flight or already succeeded (the window is about to close).
    var canSend: Bool {
        !trimmedMessage.isEmpty && phase != .sending && phase != .success
    }

    /// Editing after an error clears the stale error so the inline row hides.
    func handleEdit() {
        if isSending { return }
        if case .failed = phase { phase = .idle }
    }

    /// Return the dialog to a clean idle state. The `Window` scene retains this
    /// view's `@State` (and therefore this model instance) across close/reopen,
    /// so without an explicit reset a reopened window would still show the
    /// previous submission's `.success` / `.failed` state. Called on the view's
    /// appear AND disappear so every close path — Cancel, the auto-close after a
    /// successful send, and the red traffic-light button — lands the next open
    /// on a fresh form. No-ops mid-send so we never yank an in-flight request's
    /// state out from under it.
    func reset() {
        guard !isSending else { return }
        kind = .feedback
        message = ""
        phase = .idle
    }

    /// Switch tabs. Blocked mid-send; clears a stale error on switch. The typed
    /// message is intentionally preserved across a tab switch.
    func select(_ kind: FeedbackKind) {
        guard !isSending else { return }
        self.kind = kind
        if case .failed = phase { phase = .idle }
    }

    /// Submit the current message. On success advances to `.success` and, after
    /// a brief confirmation beat, invokes `onSuccess` (the view closes the
    /// window). On failure the typed message is left untouched so nothing is
    /// lost and the user can retry.
    func submit(userEmail: String?, onSuccess: @escaping () -> Void) {
        guard canSend else { return }
        phase = .sending
        Task { @MainActor in
            do {
                try await service.submit(kind: kind, message: message, userEmail: userEmail)
                phase = .success
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onSuccess()
            } catch let error as FeedbackError {
                phase = .failed(error.userMessage)
            } catch {
                phase = .failed("Couldn\u{2019}t send your feedback. Please try again.")
            }
        }
    }
}

// MARK: - FeedbackView

struct FeedbackView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    /// The verified trial email is the one account-identifying address the app
    /// holds locally (see TrialCreditsManager); `nil` when never verified /
    /// signed out, in which case the report is sent without an email.
    @Environment(TrialCreditsManager.self) private var trialCredits

    @State private var model = FeedbackModel()
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            header
            tabSwitcher

            if model.isSuccess {
                successState
            } else {
                editor
                if case .failed(let message) = model.phase {
                    errorRow(message)
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(VFSpacing.xl)
        .frame(width: FeedbackScene.preferredWidth, height: FeedbackScene.preferredHeight)
        .background(Color.vfPanelBackground)
        .applyFeedbackWindowChrome()
        .onAppear {
            // Clear any state retained from a previous open before showing the
            // form, then focus the editor.
            model.reset()
            editorFocused = true
        }
        // Reset on close too, so the retained @State is already clean for the
        // next open even on paths that don't fire onAppear (e.g. the window is
        // only hidden, not destroyed).
        .onDisappear { model.reset() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: VFSpacing.md) {
            Image(systemName: headerIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.vfBrandAccent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.vfTextPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.vfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerIcon: String {
        switch model.kind {
        case .issue:    return "ladybug"
        case .feedback: return "lightbulb"
        }
    }

    private var title: String {
        switch model.kind {
        case .issue:    return "Report an Issue"
        case .feedback: return "Share Feedback"
        }
    }

    private var subtitle: String {
        switch model.kind {
        case .issue:
            return "Tell us what went wrong, with steps to reproduce if you can. Not for account or billing help."
        case .feedback:
            return "Ideas, feature requests, praise, or general feedback. Not for support issues."
        }
    }

    // MARK: Tab switcher

    private var tabSwitcher: some View {
        HStack(spacing: VFSpacing.sm) {
            tabButton("Report an issue", kind: .issue)
            tabButton("Share feedback", kind: .feedback)
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ label: String, kind: FeedbackKind) -> some View {
        let isSelected = model.kind == kind
        return Button {
            model.select(kind)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.vfTextPrimary : Color.vfTextSecondary)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, VFSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                        .fill(isSelected ? Color.vfCardBackground : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.sm, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.vfBrandAccent.opacity(0.4) : Color.vfHairline,
                            lineWidth: 0.5
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSending)
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .fill(Color.vfCardBackground)
            RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                .strokeBorder(Color.vfHairline, lineWidth: 0.5)

            TextEditor(text: $model.message)
                .focused($editorFocused)
                .font(.system(size: 13))
                .foregroundStyle(Color.vfTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, VFSpacing.sm)
                .disabled(model.isSending)
                .onChange(of: model.message) { _, _ in model.handleEdit() }

            // TextEditor has no native placeholder — overlay one while empty.
            if model.message.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.vfTextTertiary)
                    // Match the editor's text origin: our own padding (sm) plus
                    // the NSTextView's ~5pt line-fragment inset horizontally.
                    // Vertically it lines up with our padding directly — any
                    // extra offset drops the placeholder below the caret.
                    .padding(.horizontal, VFSpacing.sm + 5)
                    .padding(.vertical, VFSpacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
    }

    private var placeholder: String {
        switch model.kind {
        case .issue:    return "Describe the issue you ran into\u{2026}"
        case .feedback: return "How can we make Zerro better for you?"
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Color.vfWarningAmber)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Success

    private var successState: some View {
        VStack(spacing: VFSpacing.md) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.vfSuccessGreen)
            Text(model.kind == .issue ? "Thanks for the report!" : "Thanks for the feedback!")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.vfTextPrimary)
            Text("We read every message.")
                .font(.system(size: 12))
                .foregroundStyle(Color.vfTextSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: VFSpacing.md) {
            Button("Cancel", action: close)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.vfTextSecondary)
                .disabled(model.isSending)

            Spacer(minLength: 0)

            if !model.isSuccess {
                sendButton
            }
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            HStack(spacing: VFSpacing.sm) {
                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 12, height: 12)
                        .tint(Color.vfOnBrand)
                }
                Text(sendButtonLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            // Disabled keeps its own legible treatment instead of dimming the
            // whole button: a faint tinted chip with secondary-text label, so
            // "Send message" stays readable until there's something to send.
            .foregroundStyle(model.canSend ? Color.vfOnBrand : Color.vfTextSecondary)
            .padding(.horizontal, VFSpacing.lg)
            .padding(.vertical, VFSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.md, style: .continuous)
                    .fill(model.canSend ? Color.vfBrandAccent : Color.vfBrandAccent.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
    }

    private var sendButtonLabel: String {
        if model.isSending { return "Sending\u{2026}" }
        if case .failed = model.phase { return "Try again" }
        return "Send message"
    }

    // MARK: Actions

    private func send() {
        model.submit(userEmail: trialCredits.rememberedEmail, onSuccess: close)
    }

    private func close() {
        dismissWindow(id: FeedbackScene.windowID)
    }
}

// MARK: - Preview

#Preview("Feedback") {
    FeedbackView()
        .environment(TrialCreditsManager.inMemory())
}
