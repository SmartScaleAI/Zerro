//
//  HotkeyDisplay.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 11 (revision 2) — custom hotkey UI that replaces the
//  KeyboardShortcuts library's default Recorder appearance. The
//  library's stock view renders one rounded pill containing the
//  shortcut symbols (e.g. "⇧⌘R") with a cancel button. The Zerro
//  design wants three (or N) separate dark keycap squares — one per
//  modifier + one for the key — at rest, with the library's native
//  recording UI surfacing only while the user is actively rebinding.
//
//  How the swap works:
//    • At rest, `IdleKeycapDisplay` reads the current shortcut from
//      `KeyboardShortcuts.getShortcut(for:)` and renders one keycap
//      per component (modifiers in canonical macOS order ⌃ ⌥ ⇧ ⌘,
//      then the key).
//    • On tap, `isRecording` flips true; we render a
//      `FocusedRecorder` (our own NSViewRepresentable around the
//      library's public RecorderCocoa) which auto-becomes-first-
//      responder on mount so the user doesn't need a second click.
//    • `isRecording` flips back to false when:
//        - The library's RecorderCocoa reports a shortcut change
//          (success path, via its onChange callback).
//        - The library posts its internal "active status" notification
//          with `isActive: false` (ESC, blur, click-outside).
//
//  The "isActive" notification uses the library's internal Notification
//  name string (`KeyboardShortcuts_recorderActiveStatusDidChange`),
//  which isn't part of the library's public API. If a future library
//  version renames it, the worst-case UX is "the recording state
//  persists until the user clicks again" — not a crash, not a wrong
//  binding. Documented here so the failure mode is obvious if it ever
//  fires.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

struct HotkeyDisplay: View {
    let name: KeyboardShortcuts.Name

    @State private var isRecording: Bool = false
    /// Bumped after every shortcut change so the idle display re-reads
    /// the latest value from KeyboardShortcuts (which stores in
    /// UserDefaults under the hood — there's no SwiftUI binding we can
    /// subscribe to without one).
    @State private var refreshTick: Int = 0

    var body: some View {
        Group {
            if isRecording {
                FocusedRecorder(name: name) { _ in
                    refreshTick &+= 1
                    isRecording = false
                }
                // Match the rough resting-state width so the section
                // row doesn't reflow when switching states.
                .frame(minWidth: 130, minHeight: 24)
            } else {
                IdleKeycapDisplay(
                    shortcut: KeyboardShortcuts.getShortcut(for: name)
                )
                .id(refreshTick)
                // .fixedSize() makes the keycap row exactly its
                // intrinsic width so the Spacer in SettingsRow lines
                // its right edge up with the other trailing controls
                // (Verified pill, Revalidate button, etc.) — without
                // it, a stale frame from the isRecording branch could
                // leak through the Group and leave visible gap before
                // the card right edge.
                .fixedSize()
                .onTapGesture { isRecording = true }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(rawValue: "KeyboardShortcuts_recorderActiveStatusDidChange")
            )
        ) { note in
            if let isActive = note.userInfo?["isActive"] as? Bool, !isActive {
                refreshTick &+= 1
                isRecording = false
            }
        }
    }
}

// MARK: - Idle keycap display

private struct IdleKeycapDisplay: View {
    let shortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        // Round 3: 3pt spacing so the keycaps read as a single
        // shortcut group rather than three separate buttons.
        HStack(spacing: 3) {
            if let labels, !labels.isEmpty {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    keyCap(label)
                }
            } else {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.vfTextTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .help("Click to record a new shortcut")
    }

    /// One label per keycap, via the shared `keycapLabels` formatter
    /// (HotkeySymbols.swift) so this view and the menu-bar panel's
    /// hotkey hints always agree on glyphs and modifier ordering.
    private var labels: [String]? {
        guard let labels = shortcut?.keycapLabels, !labels.isEmpty else { return nil }
        return labels
    }

    private func keyCap(_ label: String) -> some View {
        // Round 3: 28×28pt with 12pt corner radius per spec. minWidth
        // (not fixed width) so a multi-character key like "F1" can
        // grow horizontally without pushing the modifier caps
        // off-center; minHeight keeps the row's vertical rhythm
        // stable across single/multi-char keys.
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.vfTextPrimary)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.vfControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
    }
}

// MARK: - Focused recorder

/// Wraps the library's public RecorderCocoa so we can auto-focus it on
/// mount. Without this, switching `isRecording` to true would render
/// the recorder but the user would need a second click to enter the
/// library's "Type a shortcut..." state. The async make-first-responder
/// gives SwiftUI time to attach the NSView to a window.
private struct FocusedRecorder: NSViewRepresentable {
    typealias NSViewType = KeyboardShortcuts.RecorderCocoa

    let name: KeyboardShortcuts.Name
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: name) { newShortcut in
            onChange(newShortcut)
        }
        DispatchQueue.main.async {
            recorder.window?.makeFirstResponder(recorder)
        }
        return recorder
    }

    func updateNSView(_ nsView: NSViewType, context: Context) {}
}

#Preview {
    VStack(spacing: VFSpacing.lg) {
        HotkeyDisplay(name: .toggleRecording)
            .padding()
            .background(Color.vfCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .padding()
    .frame(width: 320)
    .background(Color.vfPanelBackground)
}
