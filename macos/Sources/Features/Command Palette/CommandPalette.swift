import SwiftUI

struct CommandOption: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let description: String?
    let symbols: [String]?
    let leadingIcon: String?
    let badge: String?
    let emphasis: Bool
    let action: () -> Void
    
    init(
        title: String,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        badge: String? = nil,
        emphasis: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.badge = badge
        self.emphasis = emphasis
        self.action = action
    }

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [CommandOption]
    @State private var query = ""
    @State private var selectedIndex: UInt?
    @State private var hoveredOptionID: UUID?
    @FocusState private var isTextFieldFocused: Bool

    // The options that we should show, taking into account any filtering from
    // the query.
    var filteredOptions: [CommandOption] {
        if query.isEmpty {
            return options
        } else {
            return options.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    var selectedOption: CommandOption? {
        guard let selectedIndex else { return nil }
        return if selectedIndex < filteredOptions.count {
            filteredOptions[Int(selectedIndex)]
        } else {
            filteredOptions.last
        }
    }

    var body: some View {
        let scheme: ColorScheme = if OSColor(backgroundColor).isLightColor {
            .light
        } else {
            .dark
        }

        VStack(alignment: .leading, spacing: 0) {
            CommandPaletteQuery(query: $query, isTextFieldFocused: _isTextFieldFocused) { event in
                switch (event) {
                case .exit:
                    isPresented = false

                case .submit:
                    isPresented = false
                    selectedOption?.action()

                case .move(.up):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt(filteredOptions.count)
                    selectedIndex = (current == 0)
                        ? UInt(filteredOptions.count - 1)
                        : current - 1

                case .move(.down):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt.max
                    selectedIndex = (current >= UInt(filteredOptions.count - 1))
                        ? 0
                        : current + 1

                case .move(_):
                    // Unknown, ignore
                    break
                }
            }
            .onChange(of: query) { newValue in
                // If the user types a query then we want to make sure the first
                // value is selected. If the user clears the query and we were selecting
                // the first, we unset any selection.
                if !newValue.isEmpty {
                    if selectedIndex == nil {
                        selectedIndex = 0
                    }
                } else {
                    if let selectedIndex, selectedIndex == 0 {
                        self.selectedIndex = nil
                    }
                }
            }

            Divider()

            CommandTable(
                options: filteredOptions,
                selectedIndex: $selectedIndex,
                hoveredOptionID: $hoveredOptionID) { option in
                    isPresented = false
                    option.action()
            }
        }
        .frame(maxWidth: 500)
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Rectangle()
                    .fill(backgroundColor)
                    .blendMode(.color)
            }
                .compositingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
        )
        .shadow(radius: 32, x: 0, y: 12)
        .padding()
        .environment(\.colorScheme, scheme)
        .onChange(of: isPresented) { newValue in
            // Reset focus when quickly showing and hiding.
            // macOS will destroy this view after a while,
            // so task/onAppear will not be called again.
            // If you toggle it rather quickly, we reset
            // it here when dismissing.
            isTextFieldFocused = newValue
            if !isPresented {
                // This is optional, since most of the time
                // there will be a delay before the next use.
                // To keep behavior the same as before, we reset it.
                query = ""
            }
        }
        .task {
            // Grab focus on the first appearance.
            // This happens right after onAppear,
            // so we don’t need to dispatch it again.
            // Fixes: https://github.com/ghostty-org/ghostty/issues/8497
            // Also fixes initial focus while animating.
            isTextFieldFocused = isPresented
        }
    }
}

/// The text field for building the query for the command palette.
fileprivate struct CommandPaletteQuery: View {
    @Binding var query: String
    var onEvent: ((KeyboardEvent) -> Void)? = nil
    @FocusState private var isTextFieldFocused: Bool

    init(query: Binding<String>, isTextFieldFocused: FocusState<Bool>, onEvent: ((KeyboardEvent) -> Void)? = nil) {
        _query = query
        self.onEvent = onEvent
        _isTextFieldFocused = isTextFieldFocused
    }

    enum KeyboardEvent {
        case exit
        case submit
        case move(MoveCommandDirection)
    }

    var body: some View {
        ZStack {
            Group {
                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.downArrow, modifiers: [])

                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("p"), modifiers: [.control])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("n"), modifiers: [.control])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            TextField("Execute a command…", text: $query)
                .padding()
                .font(.system(size: 20, weight: .light))
                .frame(height: 48)
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .onChange(of: isTextFieldFocused) { focused in
                    if !focused {
                        onEvent?(.exit)
                    }
                }
                .onExitCommand { onEvent?(.exit) }
                .onMoveCommand { onEvent?(.move($0)) }
                .onSubmit { onEvent?(.submit) }
        }
    }
}

fileprivate struct CommandTable: View {
    var options: [CommandOption]
    @Binding var selectedIndex: UInt?
    @Binding var hoveredOptionID: UUID?
    var action: (CommandOption) -> Void

    var body: some View {
        if options.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(options.enumerated()), id: \.1.id) { index, option in
                            CommandRow(
                                option: option,
                                isSelected: {
                                    if let selected = selectedIndex {
                                        return selected == index ||
                                            (selected >= options.count &&
                                                index == options.count - 1)
                                    } else {
                                        return false
                                    }
                                }(),
                                hoveredID: $hoveredOptionID
                            ) {
                                action(option)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 200)
                .onChange(of: selectedIndex) { _ in
                    guard let selectedIndex,
                          selectedIndex < options.count else { return }
                    proxy.scrollTo(
                        options[Int(selectedIndex)].id)
                }
            }
        }
    }
}

/// A single row in the command palette.
fileprivate struct CommandRow: View {
    let option: CommandOption
    var isSelected: Bool
    @Binding var hoveredID: UUID?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = option.leadingIcon {
                    Image(systemName: icon)
                        .foregroundStyle(option.emphasis ? Color.accentColor : .secondary)
                        .font(.system(size: 14, weight: .medium))
                }
                
                Text(option.title)
                    .fontWeight(option.emphasis ? .medium : .regular)
                
                Spacer()
                
                if let badge = option.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                }
                
                if let symbols = option.symbols {
                    ShortcutSymbolsView(symbols: symbols)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.2)
                    : (hoveredID == option.id
                       ? Color.secondary.opacity(0.2)
                       : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(option.emphasis && !isSelected ? 0.3 : 0), lineWidth: 1.5)
            )
            .cornerRadius(5)
        }
        .help(option.description ?? "")
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? option.id : nil
        }
    }
}

/// A row of Text representing a shortcut.
fileprivate struct ShortcutSymbolsView: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .frame(minWidth: 13)
            }
        }
    }
}
