//
//  ThirdPartyNoticesSheet.swift
//  Zerro
//
//  The Settings → About & Support "Third-Party Notices" sheet: renders the
//  THIRD_PARTY_NOTICES.md bundled into Zerro.app (Copy Bundle Resources;
//  the repository root file is the single source of truth) as plain,
//  selectable, scrollable text. Loading is separated into
//  `ThirdPartyNotices.load(from:)` so tests can exercise both the bundled
//  resource and the missing-resource fallback; a missing or unreadable
//  resource degrades to an explanatory message, never a crash.
//

import SwiftUI

enum ThirdPartyNotices {
    static let resourceName = "THIRD_PARTY_NOTICES"
    static let resourceExtension = "md"

    /// The bundled notices text, or nil when the resource is missing or
    /// unreadable in `bundle`.
    static func load(from bundle: Bundle = .main) -> String? {
        guard
            let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension
            ),
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.isEmpty
        else { return nil }
        return text
    }
}

struct ThirdPartyNoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Injectable for previews/tests; defaults to the app bundle.
    var bundle: Bundle = .main

    @State private var text: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Third-Party Notices")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.vfTextPrimary)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(VFSpacing.lg)

            Divider()

            if let text {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.vfTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(VFSpacing.lg)
                }
            } else {
                VStack(spacing: VFSpacing.sm) {
                    Text("The notices file could not be loaded.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vfTextPrimary)
                    Text("The full text is available as THIRD_PARTY_NOTICES.md in the Zerro source repository.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vfTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(VFSpacing.lg)
            }
        }
        .frame(width: 640, height: 520)
        .background(Color.vfPanelBackground)
        .onAppear { text = ThirdPartyNotices.load(from: bundle) }
    }
}

#Preview {
    ThirdPartyNoticesSheet()
}
