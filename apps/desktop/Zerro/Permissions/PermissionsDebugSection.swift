//
//  PermissionsDebugSection.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Phase 5, Checkpoint 1 verification surface for PermissionsManager.
//
//  Embedded inside MenuBarPanelView under a single #if DEBUG block so
//  there is exactly one debug surface in the app — clicking the menu
//  bar icon reveals the live state of both TCC permissions and offers
//  request buttons. Reset with:
//
//      tccutil reset ScreenCapture <bundle-id>
//      tccutil reset Microphone    <bundle-id>
//
//  Once the onboarding dev panel ships, this section gets removed and
//  the dev panel becomes the canonical debug surface.
//

#if DEBUG

import SwiftUI

struct PermissionsDebugSection: View {

    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        // Just the live permission status rows now — the "DEBUG" header, the
        // probe/refresh actions, and the poll toggle live in
        // MenuBarPanelView so the whole debug block reads as one flat list.
        // These lead that list.
        VStack(alignment: .leading, spacing: 8) {
            // Live TCC status + a Request button per permission. Request
            // triggers the system prompt when the status is .notDetermined.
            statusRow(label: "Screen", status: permissions.screenRecordingStatus) {
                permissions.requestScreenRecording()
            }
            statusRow(label: "Mic", status: permissions.microphoneStatus) {
                Task { await permissions.requestMicrophone() }
            }
        }
        .padding(.vertical, 4)
    }

    /// Live status + Request for one permission. Status is pushed left, the
    /// Request button pinned right via a Spacer so the two rows align. The
    /// 16pt horizontal inset matches the MenuRow label position (6 outer +
    /// 10 inner) so these line up with the rest of the debug list.
    @ViewBuilder
    private func statusRow(label: String, status: PermissionStatus, request: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 50, alignment: .leading)
            Text(statusLabel(status))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusColor(status))
            Spacer(minLength: 8)
            Button("Request") { request() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
    }

    private func statusLabel(_ status: PermissionStatus) -> String {
        switch status {
        case .notDetermined: return ".notDetermined"
        case .granted: return ".granted"
        case .denied: return ".denied"
        }
    }

    private func statusColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .notDetermined: return .secondary
        case .granted: return .green
        case .denied: return .red
        }
    }
}

#endif
