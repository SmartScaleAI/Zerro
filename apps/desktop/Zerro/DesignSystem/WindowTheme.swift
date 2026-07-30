//
//  WindowTheme.swift
//  Zerro
//
//  Shared AppKit bridge for the fixed black application theme.
//

import AppKit
import SwiftUI

/// Lightweight NSViewRepresentable used as a view background to reach the
/// hosting NSWindow after SwiftUI attaches the hierarchy.
struct WindowConfigurator: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies the parts of the Zerro theme owned by AppKit rather than SwiftUI.
/// The explicit dark appearance keeps native controls and title-bar glyphs
/// consistent even when macOS itself is using Light appearance.
@MainActor
func applyZerroBlackWindowAppearance(
    to window: NSWindow,
    transparentTitlebar: Bool = true
) {
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(Color.vfPanelBackground)
    window.titlebarAppearsTransparent = transparentTitlebar
}

extension View {
    /// Black backing + dark native chrome for standard titled Zerro windows.
    /// This deliberately preserves their title text, traffic lights, sizing,
    /// style mask, and restoration behavior.
    func applyZerroTitledWindowChrome() -> some View {
        background(
            WindowConfigurator { window in
                applyZerroBlackWindowAppearance(to: window)
            }
        )
    }
}
