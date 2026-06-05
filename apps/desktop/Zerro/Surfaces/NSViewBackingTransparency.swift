//
//  NSViewBackingTransparency.swift
//  Zerro
//
//  Created by Colin Breeding on 6/5/26.
//
//  The single place the borderless-window transparency workaround lives.
//  Borderless transparent NSWindows otherwise show an opaque backing layer
//  through any non-filled regions of the SwiftUI tree — most visibly as dark
//  notches in the rectangular window corners outside a rounded shape. Forcing
//  the view's backing layer transparent kills that.
//
//  This three-line incantation was repeated across three borderless-window
//  controllers (Pill, AreaSelector, RecordingFocus), applied once per view
//  that needs it — typically twice per controller (the hosting view plus the
//  window's contentView, since AppKit sometimes resets the layer when a view
//  is attached as contentView). Keeping it here means the workaround's purpose
//  lives in one place instead of three scattered "belt-and-suspenders" comments.
//

import AppKit

extension NSView {
    /// Forces this view's backing layer to be transparent. See file header
    /// for why borderless transparent windows need this.
    func makeBackingTransparent() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}
