//
//  SubmenuFlyoutSizingTests.swift
//  ZerroTests
//
//  Regression coverage for late-arriving microphone rows. The flyout must
//  measure SwiftUI's ideal content height rather than remain constrained to
//  the smaller panel frame created before device discovery completes.
//

import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class SubmenuFlyoutSizingTests: XCTestCase {
    func testHostingViewFittingHeightGrowsWhenRowsArrive() async {
        let hosting = FlyoutHostingView(rootView: rows(count: 1))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let initialHeight = hosting.fittingSize.height

        hosting.rootView = rows(count: 3)
        hosting.invalidateIntrinsicContentSize()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, initialHeight * 2)
    }

    private func rows(count: Int) -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Text("Microphone \(index)")
                        .frame(width: 260, alignment: .leading)
                        .padding(.vertical, MenuMetrics.rowVerticalPadding)
                }
            }
            .padding(.vertical, MenuMetrics.containerVerticalPadding)
            .fixedSize(horizontal: false, vertical: true)
        )
    }
}
