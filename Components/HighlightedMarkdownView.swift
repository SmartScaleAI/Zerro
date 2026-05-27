//
//  HighlightedMarkdownView.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/27/26.
//

import SwiftUI

struct HighlightedMarkdownView: View {
    let markdown: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            var lineStr = AttributedString(String(line))
            lineStr.foregroundColor = .vfTextPrimary

            // Highlight "## " heading marker
            if let range = lineStr.range(of: "## ") {
                lineStr[range].foregroundColor = .vfBrandBlue
                lineStr[range].font = .system(size: 12, weight: .bold, design: .monospaced)
            }

            // Highlight leading "1.", "2." style numerals
            let lineString = String(line)
            let pattern = #"^\d+\."#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: lineString, range: NSRange(location: 0, length: lineString.utf16.count)),
               let swiftRange = Range(match.range, in: lineString) {
                let matched = String(lineString[swiftRange])
                if let attrRange = lineStr.range(of: matched) {
                    lineStr[attrRange].foregroundColor = .vfWarningAmber
                    lineStr[attrRange].font = .system(size: 12, weight: .semibold, design: .monospaced)
                }
            }

            result.append(lineStr)
            if idx < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }
}

#Preview {
    HighlightedMarkdownView(markdown: """
    ## Context
    A 1:18 narrated walkthrough of the Pulse analytics login screen,
    captured while reviewing visual hierarchy and information density
    before handoff to engineering.

    ## Current State
    - Two-column form: email + password stacked on the left
    - Brand-blue "Sign in" primary CTA
    - Three social auth buttons below (Google, Microsoft, SSO)
    - Password helper text wraps to two lines at this viewport width
    - "Forgot password?" link sits adjacent to the password field

    ## Request
    1. Move "Forgot password?" into the Sign In button cluster
    """)
    .padding()
    .background(Color.vfCardBackground)
    .frame(width: 500)
}
