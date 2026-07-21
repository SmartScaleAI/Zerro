//
//  KeyCapView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct KeyCapView: View {
    let label: String
    /// Uniform zoom on every fixed metric (font, min box, padding, radius)
    /// so a chip can render larger without disturbing its proportions.
    /// Defaults to 1 — the original 10pt/16pt design — so existing call
    /// sites are unaffected.
    var scale: CGFloat = 1

    var body: some View {
        Text(label)
            .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(Color.vfTextSecondary)
            .frame(minWidth: 16 * scale, minHeight: 16 * scale)
            .padding(.horizontal, 3 * scale)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.sm * scale)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.sm * scale)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
    }
}

#Preview {
    HStack {
        KeyCapView(label: "\u{2318}")
        KeyCapView(label: "\u{2303}")
        KeyCapView(label: "R")
        KeyCapView(label: "esc")
        KeyCapView(label: "\u{21B5}")
    }
    .padding()
    .background(Color.vfPanelBackground)
}
