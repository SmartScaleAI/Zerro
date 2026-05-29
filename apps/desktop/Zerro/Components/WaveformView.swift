//
//  WaveformView.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct WaveformView: View {
    let bars: [CGFloat]   // values 0...1
    let color: Color
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: max(2, bars[i] * maxHeight))
            }
        }
        .frame(height: maxHeight)
    }
}

extension WaveformView {
    static let sampleBarsLong: [CGFloat]  = [0.3, 0.6, 0.4, 0.8, 0.5, 0.9, 0.7, 0.4, 0.6, 0.5, 0.3, 0.7, 0.6, 0.8, 0.4, 0.5, 0.7, 0.3, 0.6, 0.4, 0.8, 0.5, 0.6, 0.3, 0.5]
    static let sampleBarsShort: [CGFloat] = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.5, 0.7]
}

#Preview {
    VStack(spacing: 20) {
        WaveformView(bars: WaveformView.sampleBarsLong, color: .vfTextPrimary)
        WaveformView(bars: WaveformView.sampleBarsShort, color: .vfWarningAmber)
        WaveformView(bars: WaveformView.sampleBarsLong, color: .vfRecordingRed)
    }
    .padding()
    .background(Color.vfPanelBackground)
}
