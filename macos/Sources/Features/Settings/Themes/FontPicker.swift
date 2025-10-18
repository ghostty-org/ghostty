//
//  FontPicker.swift
//  Ghostty
//
//  Created by luca on 04.10.2025.
//

import SwiftUI

struct FontPicker: View {
    @State var font: NSFont = .systemFont(ofSize: 10)
    @EnvironmentObject var config: Ghostty.ConfigFile
    var body: some View {
        HStack {
            Text("Font")
            Spacer()
            Text(config.fontFamily.map(\.value).joined(separator: ", "))
            Button(action: {
                if NSFontPanel.shared.isVisible {
                    NSFontPanel.shared.orderOut(nil)
                    return
                }

                NSFontPanel.shared.makeKeyAndOrderFront(nil)
                let viewModel = FontPickerViewModel(config: config)
                let accessoryView = FontPickerAccessoryHostingView(viewModel: viewModel, rootView: {
                    FontPickerAccessoryView().environmentObject($0)
                })
                // after installing new fonts,
                // you have restart the hosting application to get new ones appear in the list
                NSFontPanel.shared.accessoryView = accessoryView
                NSFontPanel.shared.delegate = accessoryView
            }) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
        }
        .task {
            if let firstFont = config.fontFamily.first, let queriedFont = NSFontManager.shared.font(withFamily: firstFont.value, traits: [], weight: 100, size: 10) {
                self.font = queriedFont
            }
        }
    }

    func fontSelected() {
        font = NSFontPanel.shared.convert(font)
        guard let familyName = font.familyName else {
            return
        }
        if config.fontFamily.isEmpty {
            config.fontFamily = [.init(key: "font-family", value: familyName)]
        } else {
            config.fontFamily[0].value = familyName
        }
        config.fontStyle = font.fontDescriptor.object(forKey: .face) as? String
        config.fontStyleBold = nil
        config.fontStyleItalic = nil
        config.fontStyleBoldItalic = nil
        if font.fontDescriptor.symbolicTraits.isSuperset(of: [.bold, .italic]) {
            config.fontStyleBoldItalic = font.fontDescriptor.object(forKey: .face) as? String
        } else if font.fontDescriptor.symbolicTraits.isSuperset(of: [.bold]) {
            config.fontStyleBold = font.fontDescriptor.object(forKey: .face) as? String
        } else if font.fontDescriptor.symbolicTraits.isSuperset(of: [.italic]) {
            config.fontStyleItalic = font.fontDescriptor.object(forKey: .face) as? String
        }
    }
}

struct FontFamilySetting: Identifiable, Hashable {
    struct UnicodeRange: Identifiable, Hashable {
        let id = UUID()
        var value: ClosedRange<Unicode.Scalar>?
    }
    let id = UUID()

    var family: String
    var codePoints: [UnicodeRange] = []
    var isForBold = false
    var isForItalic = false
    var isForBoldItalic = false
}

class FontPickerViewModel: ObservableObject {
    var font: NSFont = .systemFont(ofSize: 10)
    @Published var fontSize: Double = 10
    @Published var fontSettings: [FontFamilySetting] = []
    @Published var selectedFontSettingID: FontFamilySetting.ID?
    @Published var selectedRegularStyle: String?

    var selectedFontSetting: FontFamilySetting? {
        fontSettings.first(where: { $0.id == selectedFontSettingID })
    }

    var availableFontFaces: [String]? {
        guard
            let family = selectedFontSetting?.family,
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family)
        else {
            return nil
        }
        return members.compactMap { array in
            guard array.count >= 4 else { return nil }
            // face
            return array[1] as? String
        }
    }

    init(config: Ghostty.ConfigFile) {
        fontSize = config.fontSize
        if let firstFont = config.fontFamily.first, let queriedFont = NSFontManager.shared.font(withFamily: firstFont.value, traits: [], weight: 100, size: config.fontSize) {
            font = queriedFont
            NSFontManager.shared.setSelectedFont(queriedFont, isMultiple: false)
        }
        fontSettings = config.fontFamily.map { cfg in
            FontFamilySetting(family: cfg.value)
        }
        for codePoint in config.fontCodePointMap {
            guard let range = ClosedRange<Unicode.Scalar>(hexRange: codePoint.value) else {
                continue
            }
            if let index = fontSettings.firstIndex(where: { $0.family == codePoint.key }) {
                fontSettings[index].codePoints.append(.init(value: range))
            } else {
                fontSettings.append(FontFamilySetting(family: codePoint.key, codePoints: [.init(value: range)]))
            }
        }
        selectedFontSettingID = fontSettings.first?.id
    }

    func updatePanel() {
        NSFontPanel.shared.worksWhenModal = false
        if let selectedFontSetting, let selectedFont = NSFont(name: selectedFontSetting.family, size: fontSize) {
            NSFontManager.shared.setSelectedFont(selectedFont, isMultiple: false)
        } else {
            NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        }
    }

    func fontSelected() {
        let font = NSFontPanel.shared.convert(font)
        if let idx = fontSettings.firstIndex(where: { $0.id == selectedFontSettingID }) {
            fontSettings[idx].family = font.familyName ?? ""
        }
    }

    func addNewFontFamily() {
        if let family = font.familyName {
            fontSettings.append(FontFamilySetting(family: family))
        }
    }

    func addNewCodePoint(to setting: FontFamilySetting) {
        if let idx = fontSettings.firstIndex(where: { $0.id == setting.id }) {
            fontSettings[idx].codePoints.append(.init())
        }
    }

    func deleteCodePoint(for setting: FontFamilySetting, codePointID: FontFamilySetting.UnicodeRange.ID) {
        if let idx = fontSettings.firstIndex(where: { $0.id == setting.id }) {
            fontSettings[idx].codePoints.removeAll(where: { $0.id == codePointID })
        }
    }
}

class FontPickerAccessoryHostingView<Content: View>: NSHostingView<Content>, NSFontChanging, NSWindowDelegate {
    let viewModel: FontPickerViewModel
    init(viewModel: FontPickerViewModel, rootView: (_ viewModel: FontPickerViewModel) -> Content) {
        self.viewModel = viewModel
        super.init(rootView: rootView(viewModel))
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor @preconcurrency required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    func changeFont(_ sender: NSFontManager?) {
        viewModel.fontSelected()
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.face, .size, .collection]
    }
}

struct FontPickerAccessoryView: View {
    @EnvironmentObject var viewModel: FontPickerViewModel

    var body: some View {
        VStack {
            fontTable
            optionsView
        }
        .frame(
            minWidth: 200, maxWidth: .greatestFiniteMagnitude,
            minHeight: 200, maxHeight: .greatestFiniteMagnitude
        )
        .task {
            viewModel.updatePanel()
        }
    }

    var optionsView: some View {
        VStack {
            if let faces = viewModel.availableFontFaces {
                Text("Style Overrides")
                    .font(.headline)
                Text("Selected font style will be used for the style a running program requested on the left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Regular Style", selection: $viewModel.selectedRegularStyle) {
                        ForEach(["false"] + faces, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("Bold Style", selection: $viewModel.selectedRegularStyle) {
                        ForEach(["false"] + faces, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                HStack {
                    Picker("Italic Style", selection: $viewModel.selectedRegularStyle) {
                        ForEach(["false"] + faces, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("Bold Italic Style", selection: $viewModel.selectedRegularStyle) {
                        ForEach(["false"] + faces, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
            }
        }
    }

    var fontTable: some View {
        Table(of: Binding<FontFamilySetting>.self, selection: $viewModel.selectedFontSettingID) {
            TableColumn("Family Name") { setting in
                Text(setting.wrappedValue.family)
                    .font(.custom(setting.wrappedValue.family, size: 0))
            }
            .width(200)
            TableColumn("Code Points") { setting in
                VStack {
                    ForEach(setting.codePoints) { range in
                        CodePointView(codeRange: range, fontFamily: setting.family.wrappedValue) {
                            viewModel.deleteCodePoint(for: setting.wrappedValue, codePointID: range.wrappedValue.id)
                        }
                    }
                }
            }
            .width(200)

            TableColumn("Bold") { setting in
                Toggle("", isOn: setting.isForBold)
                    .help("Used for Bold Style")
            }
            .width(40)
            TableColumn("Italic") { setting in
                Toggle("", isOn: setting.isForItalic)
                    .help("Used for Italic Style")
            }
            .width(40)
            TableColumn("Bold Italic") { setting in
                Toggle("", isOn: setting.isForBoldItalic)
                    .help("Used for Bold Italic Style")
            }
            .width(80)
        } rows: {
            ForEach($viewModel.fontSettings) {
                TableRow($0)
            }
        }
        .contextMenu(forSelectionType: FontFamilySetting.ID.self) { ids in
            if !ids.isEmpty {
                if let font = viewModel.fontSettings.first(where: { ids.contains($0.id) }), !font.family.isEmpty {
                    Button {
                        viewModel.addNewCodePoint(to: font)
                    } label: {
                        Label("Add code points for \(font.family)", systemImage: "guidepoint.vertical.numbers")
                    }
                }
                Button("Delete", systemImage: "trash") {
                    viewModel.fontSettings.removeAll(where: { ids.contains($0.id) })
                }
                .tint(.red)
            } else {
                Button {
                    viewModel.addNewFontFamily()
                } label: {
                    Label("Add Font", systemImage: "character")
                }
            }
        }
    }
}

struct CodePointView: View {
    @Binding var codeRange: FontFamilySetting.UnicodeRange
    let fontFamily: String
    let onDelete: () -> Void
    @State private var range = ""
    @State private var isRangeValid = true

    var body: some View {
        HStack(spacing: 0) {
            TextField("U+1234-U+ABCD", text: $range)
                .font(.body.monospaced())
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isRangeValid ? Color.secondary : Color.red, lineWidth: 1)
                )
                .onSubmit(updateRange)
            if let preview = codeRange.value?.description {
                Text(preview)
                    .font(.custom(fontFamily, size: 0))
                    .padding(.leading, 3)
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .help("Delete this range")
            .padding(.leading, 3)
        }
        .task {
            range = codeRange.value?.representedString ?? ""
        }
    }

    private func updateRange() {
        let parts = range.split(separator: "-").map(String.init(_:))

        guard
            let start = parts.first,
            let lowerBound = Unicode.Scalar(hexValue: start)
        else {
            isRangeValid = false
            return
        }
        isRangeValid = true
        if parts.count > 1, let upperBound = Unicode.Scalar(hexValue: parts[1]) {
            codeRange.value = lowerBound ... upperBound
        } else {
            codeRange.value = lowerBound ... lowerBound
        }
    }
}

extension Unicode.Scalar {
    init?(hexValue: String) {
        let hex = hexValue.replacingOccurrences(of: "U+", with: "")
            .replacingOccurrences(of: "u+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt32(hex, radix: 16) else { return nil }
        self.init(value)
    }

    var hexValue: String {
        String(format: "U+%04X", value)
    }
}

extension ClosedRange where Bound == Unicode.Scalar {
    init?(hexRange: String) {
        let parts = hexRange.split(separator: "-")
        guard
            parts.count == 2,
            let lower = Unicode.Scalar(hexValue: String(parts[0])),
            let upper = Unicode.Scalar(hexValue: String(parts[1]))
        else {
            return nil
        }
        self = lower ... upper
    }

    var description: String {
        [lowerBound.description, upperBound.description].joined(separator: " - ")
    }

    var representedString: String {
        [lowerBound.hexValue, upperBound.hexValue].joined(separator: "-")
    }
}
