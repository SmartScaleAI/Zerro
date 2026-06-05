//
//  NSScreenDisplayID.swift
//  Zerro
//
//  Created by Colin Breeding on 6/5/26.
//
//  The stable, unique hardware identifier for the display backing an
//  NSScreen. AppKit exposes it only as the `NSScreenNumber` entry in
//  `deviceDescription` (an NSNumber), so unwrapping it correctly is a
//  multi-step dance that was being open-coded at several sites. This is
//  the single place it lives.
//
//  Why this matters (L1): `NSScreen.localizedName` is NOT unique — two
//  identical external monitors share the same name, so matching a
//  selected display by name can resolve to the wrong panel. The
//  CGDirectDisplayID is the unique hardware identity and is what the
//  selection→capture handoff matches on.
//

import AppKit
import CoreGraphics

extension NSScreen {
    /// The `CGDirectDisplayID` of the display backing this screen, or nil
    /// if the device description doesn't carry it (should not happen for a
    /// live screen, but the API surface makes it optional).
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
