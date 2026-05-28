//
//  PermissionsDebugSection.swift
//  VisualFlowAI
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

    @State private var isPolling: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEBUG \u{00B7} PERMISSIONS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            row(label: "Screen", status: permissions.screenRecordingStatus) {
                permissions.requestScreenRecording()
            }
            row(label: "Mic", status: permissions.microphoneStatus) {
                Task { await permissions.requestMicrophone() }
            }

            HStack(spacing: 8) {
                Button("Refresh") { permissions.refreshStatuses() }
                    .controlSize(.small)
                Toggle("Poll", isOn: $isPolling)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: isPolling) { _, newValue in
                        if newValue { permissions.startPolling() }
                        else { permissions.stopPolling() }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(label: String, status: PermissionStatus, request: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 50, alignment: .leading)
            Text(statusLabel(status))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusColor(status))
                .frame(width: 110, alignment: .leading)
            Button("Request") { request() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
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
