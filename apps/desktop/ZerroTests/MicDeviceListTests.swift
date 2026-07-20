//
//  MicDeviceListTests.swift
//  ZerroTests
//
//  H-13 — the Settings mic picker must refresh on device hot-plug.
//
//  The picker's device list used to load once in `.onAppear` and never
//  update, so plugging/unplugging a mic while Settings sat open left a
//  stale list. `MicDeviceList` re-runs discovery whenever AVFoundation
//  posts wasConnected/wasDisconnected. These tests drive the model with an
//  injected device source (AVCaptureDevice can't be constructed in a unit
//  test) and post the real notification names on NotificationCenter.default;
//  the SwiftUI wiring (onAppear/onDisappear start/stop) is review-verified.
//
//  The selection-fallback contract needs no new test: the picker binding
//  already falls back visually to "System Default" when the stored ID isn't
//  in `devices`, so a refreshed list that no longer contains the selected
//  device degrades gracefully by construction.
//

import AVFoundation
import XCTest
@testable import Zerro

@MainActor
final class MicDeviceListTests: XCTestCase {

    private let builtIn = MicDeviceList.Device(id: "built-in", name: "MacBook Pro Microphone")
    private let usb = MicDeviceList.Device(id: "usb-42", name: "USB Microphone")

    /// Polls until the model's devices match `expected` (the hot-plug
    /// handler hops to the MainActor via a Task, so the refresh lands a
    /// runloop turn after the post). ~1s ceiling before failing.
    private func waitForDevices(
        _ list: MicDeviceList,
        toEqual expected: [MicDeviceList.Device],
        message: String
    ) async {
        for _ in 0..<100 {
            if list.devices == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(list.devices, expected, message)
    }

    func testRefreshRepopulatesFromInjectedSource() {
        var available = [builtIn]
        let list = MicDeviceList(provider: { available })

        XCTAssertEqual(list.devices, [], "no discovery before the first refresh")
        list.refresh()
        XCTAssertEqual(list.devices, [builtIn])

        available = [builtIn, usb]
        list.refresh()
        XCTAssertEqual(list.devices, [builtIn, usb])
    }

    /// Plugging a mic in posts wasConnected → the list must pick it up
    /// without another explicit refresh.
    func testConnectNotificationTriggersRefresh() async {
        var available = [builtIn]
        let list = MicDeviceList(provider: { available })
        list.refresh()
        list.startObserving()
        defer { list.stopObserving() }

        available = [builtIn, usb]
        NotificationCenter.default.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)

        await waitForDevices(list, toEqual: [builtIn, usb],
                             message: "a connect notification must refresh the device list")
    }

    /// Unplugging the selected mic posts wasDisconnected → the vanished
    /// device must leave the list (the picker binding then falls back to
    /// System Default by construction).
    func testDisconnectNotificationDropsVanishedDevice() async {
        var available = [builtIn, usb]
        let list = MicDeviceList(provider: { available })
        list.refresh()
        list.startObserving()
        defer { list.stopObserving() }

        available = [builtIn]
        NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        await waitForDevices(list, toEqual: [builtIn],
                             message: "a disconnect notification must drop the vanished device")
    }

    /// After stopObserving (the row's onDisappear), hot-plug notifications
    /// must no longer reach the model — no observers leak past the view.
    func testStopObservingEndsRefreshes() async {
        var available = [builtIn]
        let list = MicDeviceList(provider: { available })
        list.refresh()
        list.startObserving()
        list.stopObserving()

        available = [builtIn, usb]
        NotificationCenter.default.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)

        // Give a leaked observer's MainActor hop ample time to land before
        // asserting nothing changed.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(list.devices, [builtIn],
                       "no refresh may fire once observation has stopped")
    }
}
