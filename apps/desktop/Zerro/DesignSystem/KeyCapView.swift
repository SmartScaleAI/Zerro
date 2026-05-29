//
//  KeyCapView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.vfTextSecondary)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.sm)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.sm)
                    .strokeBorder(Color.vfHairline, lineWidth: 0.5)
            )
    }
}

#Preview {
    HStack {
        KeyCapView(label: "\u{2318}")
        KeyCapView(label: "\u{21E7}")
        KeyCapView(label: "R")
        KeyCapView(label: "esc")
        KeyCapView(label: "\u{21B5}")
    }
    .padding()
    .background(Color.vfPanelBackground)
}
