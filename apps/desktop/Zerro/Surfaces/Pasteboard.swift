//
//  Pasteboard.swift
//  Zerro
//
//  Created by Colin Breeding on 6/5/26.
//
//  The single place "copy a prompt to the clipboard" lives. The same
//  clearContents()-then-setString pair was open-coded at four sites
//  (the Pill Copy button, the two MenuBar panel copy paths, and the
//  Recent Prompts row) — consolidating it means the contract has one
//  home if it ever changes.
//
//  clearContents() drops anything the user had on the pasteboard before;
//  that's the intended behavior — the Copy contract is "the prompt is now
//  on your clipboard", not "the prompt has been added to whatever was there".
//

import AppKit

enum Pasteboard {
    /// Replaces the general pasteboard's contents with `string` as plain text.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
