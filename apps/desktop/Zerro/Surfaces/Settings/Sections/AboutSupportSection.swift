//
//  AboutSupportSection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 — About & Support section of the redesigned Settings layout
//  plus the footer link row:
//    1. Version       — right-aligned monospace, from CFBundle keys.
//    2. Copy Diagnostic Info — button that drops DiagnosticsCollector's
//                       snapshot on the clipboard for support emails.
//                       Phase 13 will graduate this into structured
//                       `os_log` collection.
//    3. Send Feedback — navigation row opening the project mailto URL.
//
//  Footer is a separate sibling (not inside the card) so it sits
//  centered below the section card the way the screenshots show.
//

import AppKit
import SwiftUI

struct AboutSupportSection: View {
    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            SettingsSection("About & Support") {
                VersionRow()
                SettingsRowDivider()
                CopyDiagnosticInfoRow()
                SettingsRowDivider()
                SendFeedbackRow()
            }
            SettingsFooter()
        }
    }
}

// MARK: - Constants

/// Centralized URLs / addresses the About section links to. Pulled out
/// so they live in one place rather than scattered through view files.
/// Privacy doesn't have a published URL yet — the Footer renders that
/// link as a non-clickable placeholder until one exists.
enum SupportURLs {
    static let website = URL(string: "https://getzerro.app")!
    static let feedbackMailto = URL(string: "mailto:feedback@zerro.app")!
}

// MARK: - Rows

private struct VersionRow: View {
    var body: some View {
        SettingsRow(label: "Version", description: nil) {
            Text("Zerro \(DiagnosticsCollector.appVersionString())")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.vfTextSecondary)
        }
    }
}

private struct CopyDiagnosticInfoRow: View {
    @Environment(PermissionsManager.self) private var permissions
    @Environment(PreferencesStore.self) private var preferences

    @State private var didCopy: Bool = false

    var body: some View {
        SettingsRow(
            label: "Copy Diagnostic Info",
            description: "System details to attach to a bug report."
        ) {
            Button(action: copy) {
                HStack(spacing: 4) {
                    if didCopy {
                        Image(systemName: "checkmark")
                    }
                    Text(didCopy ? "Copied" : "Copy")
                }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }

    private func copy() {
        DiagnosticsCollector.copyToPasteboard(
            permissions: permissions,
            preferences: preferences
        )
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { didCopy = false }
        }
    }
}

private struct SendFeedbackRow: View {
    var body: some View {
        SettingsNavigationRow(
            label: "Send Feedback",
            description: "Opens a new message in your mail app."
        ) {
            NSWorkspace.shared.open(SupportURLs.feedbackMailto)
        }
    }
}

// MARK: - Footer

struct SettingsFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                FooterLink("Website", url: SupportURLs.website)
                separator
                // Privacy is a placeholder until a real URL exists —
                // FooterLink with a nil URL renders the label without
                // a hover/click affordance.
                FooterLink("Privacy", url: nil)
            }
            Text("\u{00A9} \(Self.currentYearString) Zerro")
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VFSpacing.md)
    }

    private var separator: some View {
        Text(" \u{00B7} ")
            .font(.system(size: 11))
            .foregroundStyle(Color.vfTextTertiary)
    }

    /// Reads the current year at access time. The footer re-evaluates
    /// on every Settings open, so the copyright stays current without
    /// touching a literal each January.
    private static var currentYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }
}

private struct FooterLink: View {
    let title: String
    let url: URL?

    @State private var isHovered = false

    init(_ title: String, url: URL?) {
        self.title = title
        self.url = url
    }

    var body: some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? Color.vfTextPrimary : Color.vfTextSecondary)
                    .underline(isHovered)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        } else {
            // Placeholder: no underline, no hover, no click. Reads
            // visually identical to a resting-state link so swapping
            // in a real URL later is a one-line change.
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.vfTextSecondary)
        }
    }
}

#Preview {
    AboutSupportSection()
        .environment(PermissionsManager())
        .environment(PreferencesStore())
        .padding()
        .frame(width: 720)
        .background(Color.vfPanelBackground)
}
