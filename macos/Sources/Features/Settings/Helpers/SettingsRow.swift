//
//  SettingsRow.swift
//  Ghostty
//
//  Created by luca on 20.10.2025.
//

import SwiftUI

struct SettingsRow<Content: View, Footer: View>: View {
    let content: Content
    var footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.footer = footer()
    }
    var body: some View {
        VStack(alignment: .leading) {
            content
            footer
        }
    }
}

extension SettingsRow where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content) {
            EmptyView()
        }
    }
}

extension SettingsRow where Footer == Text? {
    init(help: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            if let help {
                Text(help)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    func tip(_ text: String) -> Self {
        var copy = self
        copy.footer = Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
        return copy
    }
}

struct CollapsedSettingsRow<Label: View, PopoverAnchor: View, PopoverContent: View>: View {
    let label: Label
    let popoverAnchor: PopoverAnchor
    let popoverContent: PopoverContent
    let help: String?
    let attachmentAnchor: PopoverAttachmentAnchor
    @State private var isPopoverPresented: Bool = false

    init(help: String? = nil, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), @ViewBuilder label: () -> Label, @ViewBuilder popoverAnchor: () -> PopoverAnchor, @ViewBuilder popoverContent: () -> PopoverContent) {
        self.label = label()
        self.popoverAnchor = popoverAnchor()
        self.popoverContent = popoverContent()
        self.help = help
        self.attachmentAnchor = attachmentAnchor
    }

    var body: some View {
        SettingsRow(help: help) {
            HStack {
                label
                Spacer()
                Button {
                    isPopoverPresented.toggle()
                } label: {
                    popoverAnchor
                }
                .buttonStyle(.borderless)
                .tint(.accentColor)
                .popover(isPresented: $isPopoverPresented, attachmentAnchor: attachmentAnchor) {
                    popoverContent
                }
            }
        }
    }
}
