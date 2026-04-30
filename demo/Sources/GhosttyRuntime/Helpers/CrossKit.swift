// This file is a helper to bridge some types that are effectively identical
// between AppKit and UIKit.

import SwiftUI

#if canImport(AppKit)

import AppKit

typealias OSView = NSView
typealias OSColor = NSColor
typealias OSSize = NSSize
typealias OSPasteboard = NSPasteboard

protocol OSViewRepresentable: NSViewRepresentable where NSViewType == OSViewType {
    associatedtype OSViewType: NSView
    func makeOSView(context: Context) -> OSViewType
    func updateOSView(_ osView: OSViewType, context: Context)
}

extension OSViewRepresentable {
    func makeNSView(context: Context) -> OSViewType {
        makeOSView(context: context)
    }

    func updateNSView(_ nsView: OSViewType, context: Context) {
        updateOSView(nsView, context: context)
    }
}

#elseif canImport(UIKit)

import UIKit

typealias OSView = UIView
typealias OSColor = UIColor
typealias OSSize = CGSize
typealias OSPasteboard = UIPasteboard

protocol OSViewRepresentable: UIViewRepresentable {
    associatedtype OSViewType: UIView
    func makeOSView(context: Context) -> OSViewType
    func updateOSView(_ osView: OSViewType, context: Context)
}

extension OSViewRepresentable {
    func makeUIView(context: Context) -> OSViewType {
        makeOSView(context: context)
    }

    func updateUIView(_ uiView: OSViewType, context: Context) {
        updateOSView(uiView, context: context)
    }
}

#endif
