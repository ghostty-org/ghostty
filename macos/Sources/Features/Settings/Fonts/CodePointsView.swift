//
//  CodePointsView.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import SwiftUI

struct CodePointsView: View {
    @State private var range = ""
    @Binding var codeRanges: [FontFamilySetting.UnicodeRange]

    var body: some View {
        TextField("", text: $range)
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .onSubmit(updateRanges)
            .focusable()
            .task {
                range = codeRanges.map(\.representedString).joined(separator: ",")
            }
    }

    func updateRanges() {
        let ranges = range.split(separator: ",").compactMap(self.rangeFor(_:))
        withAnimation(.smooth) {
            codeRanges = ranges
        }
    }

    func rangeFor(_ hexRange: Substring) -> ClosedRange<Unicode.Scalar>? {
        let parts = hexRange.split(separator: "-").map(String.init(_:))

        guard
            let start = parts.first,
            let lowerBound = Unicode.Scalar(hexValue: start)
        else {
            return nil
        }
        if parts.count > 1, let upperBound = Unicode.Scalar(hexValue: parts[1]) {
            return lowerBound ... upperBound
        } else {
            return lowerBound ... lowerBound
        }
    }
}
