import SwiftUI
import AppKit

private final class QuickCommandsKeyMonitor: ObservableObject {
    private var monitor: Any?
    var isModalPresented: Bool = false
    var onMove: ((Int) -> Void)?
    var onExecute: (() -> Void)?
    var onInsert: (() -> Void)?
    var onCancel: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // If a modal sheet is presented, let the sheet handle all keys
            guard !self.isModalPresented else { return event }

            // Check if key window matches
            guard let window = event.window, window == NSApp.keyWindow else { return event }

            // If the terminal surface has focus, pass event through untouched!
            if window.firstResponder is Ghostty.OSSurfaceView {
                return event
            }

            switch event.keyCode {
            case 126: // Up Arrow
                self.onMove?(-1)
                return nil
            case 125: // Down Arrow
                self.onMove?(1)
                return nil
            case 36: // Return / Enter
                if event.modifierFlags.contains(.option) {
                    self.onInsert?()
                } else {
                    self.onExecute?()
                }
                return nil
            case 53: // Escape
                self.onCancel?()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stop()
    }
}

struct QuickCommandsView: View {
    let configuredCommands: [QuickCommand]
    let surface: Ghostty.SurfaceView?
    let send: (QuickCommand, String?, Bool, Bool) -> Void
    var splitAndSend: ((QuickCommand, String?, Bool) -> Void)?

    @ObservedObject private var library = QuickCommandLibrary.shared
    @StateObject private var processMonitor = TerminalProcessMonitor()
    @StateObject private var keyMonitor = QuickCommandsKeyMonitor()

    @State private var editing: QuickCommand?
    @State private var parameterizing: QuickCommand?
    @State private var isCreatingGroup: Bool = false
    @State private var searchText: String = ""
    @State private var selectedGroup: String?
    @State private var isBroadcast: Bool = false
    @State private var selectedIndex: Int = 0

    @FocusState private var isSearchFocused: Bool

    private var allGroups: [String] {
        var groups = Set<String>()
        for cmd in configuredCommands {
            if let grp = cmd.group?.trimmingCharacters(in: .whitespaces), !grp.isEmpty {
                groups.insert(grp)
            }
        }
        for cmd in library.commands {
            if let grp = cmd.group?.trimmingCharacters(in: .whitespaces), !grp.isEmpty {
                groups.insert(grp)
            }
        }
        for grp in library.customGroups where !grp.isEmpty {
            groups.insert(grp)
        }
        return groups.sorted()
    }

    private func matchesFilter(_ cmd: QuickCommand) -> Bool {
        if let selectedGroup, !selectedGroup.isEmpty {
            if cmd.group != selectedGroup { return false }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return true }
        if cmd.title.lowercased().contains(query) { return true }
        if cmd.command.lowercased().contains(query) { return true }
        if let grp = cmd.group?.lowercased(), grp.contains(query) { return true }
        return false
    }

    private var filteredCommands: [(command: QuickCommand, configured: Bool)] {
        var results: [(command: QuickCommand, configured: Bool)] = []
        for cmd in configuredCommands where matchesFilter(cmd) {
            results.append((cmd, true))
        }
        for cmd in library.commands where matchesFilter(cmd) {
            results.append((cmd, false))
        }
        return results
    }

    private func countForGroup(_ group: String) -> Int {
        var count = 0
        for cmd in configuredCommands where cmd.group == group { count += 1 }
        for cmd in library.commands where cmd.group == group { count += 1 }
        return count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Text("Quick Commands")
                    .font(.headline)

                Spacer()

                // Background Jobs Indicator
                BackgroundJobsIndicator(monitor: processMonitor)

                // Broadcast toggle (SecureCRT Send to All)
                Button {
                    isBroadcast.toggle()
                } label: {
                    Image(systemName: isBroadcast ? "rectangle.split.2x2.fill" : "rectangle.split.2x2")
                        .foregroundStyle(isBroadcast ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isBroadcast ? "Broadcast active (send to all splits)" : "Broadcast: Send to all splits")
                .accessibilityLabel("Broadcast to all splits")
                .accessibilityValue(isBroadcast ? "On" : "Off")

                // Add command
                Button {
                    editing = QuickCommand(title: "", command: "", group: selectedGroup)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Command")
                .accessibilityLabel("Add Command")
                .disabled(!library.canWrite)
            }

            // SecureCRT-style Horizontal Group Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    GroupTabButton(
                        title: "All",
                        isSelected: selectedGroup == nil,
                        count: configuredCommands.count + library.commands.count
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedGroup = nil }
                    }

                    ForEach(allGroups, id: \.self) { grp in
                        GroupTabButton(
                            title: grp,
                            isSelected: selectedGroup == grp,
                            count: countForGroup(grp)
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) { selectedGroup = grp }
                        }
                    }

                    Button {
                        isCreatingGroup = true
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text("Group")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Create new command group")
                }
                .padding(.vertical, 2)
            }

            // Search Bar & Keyboard shortcuts helper
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if NSEvent.modifierFlags.contains(.option) {
                            insertFocusedCommand()
                        } else {
                            executeFocusedCommand()
                        }
                    }
                    .onExitCommand {
                        isSearchFocused = false
                        if let surface {
                            surface.window?.makeFirstResponder(surface)
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)

            if isBroadcast {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                    Text("Broadcast active: commands will be sent to all splits.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            if let error = library.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Reload Library") { library.reload() }
            }

            if configuredCommands.isEmpty && library.commands.isEmpty {
                Text("No quick commands yet. Add a command here or define quick-command in your Ghostty configuration.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if filteredCommands.isEmpty {
                Text("No commands match your search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.command.id) { index, item in
                                QuickCommandCard(
                                    command: item.command,
                                    configured: item.configured,
                                    surface: surface,
                                    shortcutNumber: index < 9 ? index + 1 : nil,
                                    isHighlighted: selectedIndex == index,
                                    onExecute: {
                                        handleExecute(item.command)
                                    },
                                    onInsert: {
                                        handleInsert(item.command)
                                    },
                                    onSplitAndRun: {
                                        handleSplitAndRun(item.command)
                                    },
                                    onDuplicate: { editing = item.command.duplicate() },
                                    onEdit: { editing = item.command },
                                    onDelete: { library.delete(item.command) }
                                )
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            scrollProxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            processMonitor.setSurfaceView(surface)
            isSearchFocused = true
            keyMonitor.onMove = { delta in navigateSelection(delta) }
            keyMonitor.onExecute = { executeFocusedCommand() }
            keyMonitor.onInsert = { insertFocusedCommand() }
            keyMonitor.onCancel = {
                isSearchFocused = false
                if let surface {
                    surface.window?.makeFirstResponder(surface)
                }
            }
            keyMonitor.start()
        }
        .onDisappear {
            keyMonitor.stop()
        }
        .onChange(of: searchText) { _ in
            selectedIndex = 0
        }
        .onChange(of: selectedGroup) { _ in
            selectedIndex = 0
        }
        .onChange(of: surface) { newSurface in
            processMonitor.setSurfaceView(newSurface)
        }
        .onChange(of: editing) { keyMonitor.isModalPresented = ($0 != nil || parameterizing != nil || isCreatingGroup) }
        .onChange(of: parameterizing) { keyMonitor.isModalPresented = (editing != nil || $0 != nil || isCreatingGroup) }
        .onChange(of: isCreatingGroup) { keyMonitor.isModalPresented = (editing != nil || parameterizing != nil || $0) }
        .sheet(item: $editing) { command in
            QuickCommandEditor(command: command, existingGroups: allGroups, library: library)
        }
        .sheet(isPresented: $isCreatingGroup) {
            QuickGroupCreationModal(library: library) { newGroup in
                selectedGroup = newGroup
            }
        }
        .sheet(item: $parameterizing) { command in
            QuickCommandParameterModal(
                command: command,
                clipboard: NSPasteboard.general.string(forType: .string),
                selection: surface?.accessibilitySelectedText()
            ) { customText, execute in
                send(command, customText, execute, isBroadcast)
                isSearchFocused = false
                if let surface {
                    surface.window?.makeFirstResponder(surface)
                }
            }
        }
    }

    private func navigateSelection(_ delta: Int) {
        let count = filteredCommands.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func executeFocusedCommand() {
        guard selectedIndex >= 0 && selectedIndex < filteredCommands.count else { return }
        handleExecute(filteredCommands[selectedIndex].command)
    }

    private func insertFocusedCommand() {
        guard selectedIndex >= 0 && selectedIndex < filteredCommands.count else { return }
        handleInsert(filteredCommands[selectedIndex].command)
    }

    private func triggerNumberShortcut(_ num: Int) {
        let index = num - 1
        guard index >= 0 && index < filteredCommands.count else { return }
        handleExecute(filteredCommands[index].command)
    }

    private func handleExecute(_ command: QuickCommand) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let selection = surface?.accessibilitySelectedText()
        if command.manualPlaceholders.isEmpty {
            let resolved = command.autoResolvedCommand(clipboard: clipboard, selection: selection)
            send(command, resolved, true, isBroadcast)
            isSearchFocused = false
            if let surface {
                surface.window?.makeFirstResponder(surface)
            }
        } else {
            parameterizing = command
        }
    }

    private func handleInsert(_ command: QuickCommand) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let selection = surface?.accessibilitySelectedText()
        if command.manualPlaceholders.isEmpty {
            let resolved = command.autoResolvedCommand(clipboard: clipboard, selection: selection)
            send(command, resolved, false, isBroadcast)
            isSearchFocused = false
            if let surface {
                surface.window?.makeFirstResponder(surface)
            }
        } else {
            parameterizing = command
        }
    }

    private func handleSplitAndRun(_ command: QuickCommand) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let selection = surface?.accessibilitySelectedText()
        if command.manualPlaceholders.isEmpty {
            let resolved = command.autoResolvedCommand(clipboard: clipboard, selection: selection)
            splitAndSend?(command, resolved, true)
        } else {
            parameterizing = command
        }
    }
}

private struct GroupTabButton: View {
    let title: String
    let isSelected: Bool
    var count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.3) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color(nsColor: .controlBackgroundColor)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

private struct BackgroundJobsIndicator: View {
    @ObservedObject var monitor: TerminalProcessMonitor
    @State private var showPopover = false

    var body: some View {
        if !monitor.recentExits.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
                Text("\(monitor.recentExits.joined(separator: ", ")) finished")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.12))
            .cornerRadius(6)
            .transition(.opacity)
        } else if !monitor.runningJobs.isEmpty {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("\(monitor.runningJobs.count) bg")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Terminal Processes")
                            .font(.headline)
                        Spacer()
                        Text("\(monitor.runningJobs.count) active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    ForEach(monitor.runningJobs) { job in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(job.isForeground ? Color.accentColor : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(job.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text("PID \(job.pid)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Kill", role: .destructive) {
                                monitor.terminateJob(job)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .frame(minWidth: 230)
            }
            .help("Active background processes on this terminal")
        }
    }
}

private struct QuickCommandCard: View, Equatable {
    let command: QuickCommand
    let configured: Bool
    let surface: Ghostty.SurfaceView?
    var shortcutNumber: Int?
    var isHighlighted: Bool = false
    let onExecute: () -> Void
    let onInsert: () -> Void
    var onSplitAndRun: (() -> Void)?
    let onDuplicate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    static func == (lhs: QuickCommandCard, rhs: QuickCommandCard) -> Bool {
        lhs.command == rhs.command &&
        lhs.configured == rhs.configured &&
        lhs.shortcutNumber == rhs.shortcutNumber &&
        lhs.isHighlighted == rhs.isHighlighted
    }

    private var isDisabled: Bool {
        surface == nil || surface?.surface == nil || surface?.readonly == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                // Clickable Title Button (executes on click)
                Button {
                    onExecute()
                } label: {
                    HStack(spacing: 6) {
                        Text(command.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
                            .lineLimit(1)

                        if let grp = command.group, !grp.isEmpty {
                            Text(grp)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
                                .foregroundStyle(Color.secondary)
                        }

                        if !command.manualPlaceholders.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 8))
                                Text("<\(command.manualPlaceholders.first ?? "")>")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(Color.accentColor)
                        } else if command.command.contains("{clipboard}") || command.command.contains("<clipboard>") {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .help("Auto-injects clipboard")
                        } else if command.command.contains("{selection}") || command.command.contains("<selection>") {
                            Image(systemName: "selection.pin.in.out")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .help("Auto-injects selected text")
                        }

                        Spacer()

                        if let num = shortcutNumber {
                            Text("⌘\(num)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help("Execute: \(command.command)")

                // Hover Split & Run Action
                if isHovered && onSplitAndRun != nil {
                    Button {
                        onSplitAndRun?()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Split terminal right and run")
                }

                // Context Menu (...)
                Menu {
                    Button("Insert in prompt") { onInsert() }
                    if onSplitAndRun != nil {
                        Button("Run in new split") { onSplitAndRun?() }
                    }
                    Button("Duplicate") { onDuplicate() }
                    if !configured {
                        Button("Edit…") { onEdit() }
                        Button("Delete", role: .destructive) { onDelete() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Options for \(command.title)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHighlighted
                            ? Color.accentColor.opacity(0.18)
                            : (isHovered ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHighlighted ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .onHover { inside in
                isHovered = inside
            }
            Divider()
                .padding(.top, 2)
        }
    }
}

private struct QuickGroupCreationModal: View {
    @ObservedObject var library: QuickCommandLibrary
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groupName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Command Group")
                .font(.headline)

            Text("Create a group to organize commands (e.g. Cisco, Linux, Docker, Git):")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Group name", text: $groupName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Group") {
                    let trimmed = groupName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        library.addGroup(trimmed)
                        onCreated(trimmed)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

private struct QuickCommandParameterModal: View {
    let command: QuickCommand
    let clipboard: String?
    let selection: String?
    let onSend: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]

    private var resolvedCommand: String {
        command.autoResolvedCommand(clipboard: clipboard, selection: selection, values: values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Parameters: \(command.title)")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("Enter values for command variables:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(command.manualPlaceholders, id: \.self) { placeholder in
                    HStack {
                        Text("<\(placeholder)>")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        TextField("Value for \(placeholder)", text: Binding(
                            get: { values[placeholder] ?? "" },
                            set: { values[placeholder] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Preview:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(resolvedCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    onSend(resolvedCommand, false)
                    dismiss()
                }
                Button("Execute") {
                    onSend(resolvedCommand, true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

private struct QuickCommandEditor: View {
    @State var command: QuickCommand
    let existingGroups: [String]
    @ObservedObject var library: QuickCommandLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(command.title.isEmpty ? "New Quick Command" : "Edit Quick Command")
                .font(.headline)

            TextField("Name", text: $command.title)
            TextField("Command (supports <var>, {clipboard}, {selection})", text: $command.command)
                .font(.system(.body, design: .monospaced))

            VStack(alignment: .leading, spacing: 4) {
                Text("Group (optional):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("e.g. Linux, Cisco, Git", text: Binding(
                        get: { command.group ?? "" },
                        set: { command.group = $0.isEmpty ? nil : $0 }
                    ))
                    if !existingGroups.isEmpty {
                        Menu("Choose...") {
                            Button("No group") { command.group = nil }
                            ForEach(existingGroups, id: \.self) { grp in
                                Button(grp) { command.group = grp }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            Toggle("Allow immediate execution", isOn: Binding(
                get: { command.action == .execute },
                set: { command.action = $0 ? .execute : .insert }
            ))

            if let error = command.validationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if library.save(command) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.validationError != nil || !library.canWrite)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Keeps the terminal subtree in the same position and identity as the panel
/// opens and closes. Resizing changes layout only, never the terminal split tree.
struct QuickCommandsLayout<Terminal: View, Sidebar: View>: View {
    @Binding var isShowing: Bool
    @Binding var width: CGFloat
    @ViewBuilder var terminal: () -> Terminal
    @ViewBuilder var sidebar: () -> Sidebar
    @State private var dragStart: CGFloat?
    @State private var hoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                terminal()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isShowing {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 5)
                        .onHover { inside in
                            guard inside != hoveringDivider else { return }
                            hoveringDivider = inside
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .onDisappear {
                            if hoveringDivider {
                                NSCursor.pop()
                                hoveringDivider = false
                            }
                            dragStart = nil
                        }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStart == nil { dragStart = bounded(width, total: geometry.size.width) }
                                width = bounded((dragStart ?? width) - value.translation.width, total: geometry.size.width)
                            }
                            .onEnded { _ in dragStart = nil })
                        .accessibilityLabel("Quick Commands Width")
                        .accessibilityValue("\(Int(width)) points")
                        .accessibilityAdjustableAction { direction in
                            width = bounded(width + (direction == .increment ? 20 : -20), total: geometry.size.width)
                        }
                    sidebar().frame(width: bounded(width, total: geometry.size.width))
                }
            }
        }
    }

    private func bounded(_ value: CGFloat, total: CGFloat) -> CGFloat {
        min(max(220, value), max(220, total - 165))
    }
}
