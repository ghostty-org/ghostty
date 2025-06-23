import AppIntents

// MARK: AppEntity

@available(macOS 14.0, *)
struct CommandEntity: AppEntity {
    let id: ID

    // Note: for macOS 26 we can move all the properties to @ComputedProperty.

    @Property(title: "Title")
    var title: String

    @Property(title: "Description")
    var description: String

    @Property(title: "Action")
    var action: String

    /// The underlying data model
    let command: Ghostty.Command

    /// A command identifier is a composite key based on the terminal and action.
    struct ID: Hashable {
        let terminalId: TerminalEntity.ID
        let actionKey: String

        init(terminalId: TerminalEntity.ID, actionKey: String) {
            self.terminalId = terminalId
            self.actionKey = actionKey
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Command Palette Command")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: command.title),
            subtitle: LocalizedStringResource(stringLiteral: command.description),
        )
    }

    static var defaultQuery = CommandQuery()

    init(_ command: Ghostty.Command, for terminal: TerminalEntity) {
        self.id = .init(terminalId: terminal.id, actionKey: command.actionKey)
        self.command = command
        self.title = command.title
        self.description = command.description
        self.action = command.action
    }
}

@available(macOS 14.0, *)
extension CommandEntity.ID: RawRepresentable {
    var rawValue: String {
        return "\(terminalId):\(actionKey)"
    }

    init?(rawValue: String) {
        let components = rawValue.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return nil }

        guard let terminalId = TerminalEntity.ID(uuidString: String(components[0])) else {
            return nil
        }

        self.terminalId = terminalId
        self.actionKey = String(components[1])
    }
}

// Required by AppEntity
@available(macOS 14.0, *)
extension CommandEntity.ID: EntityIdentifierConvertible {
    static func entityIdentifier(for entityIdentifierString: String) -> CommandEntity.ID? {
        .init(rawValue: entityIdentifierString)
    }
    
    var entityIdentifierString: String {
        rawValue
    }
}

// MARK: EntityQuery

@available(macOS 14.0, *)
struct CommandQuery: EntityQuery {
    // Inject our terminal parameter from our command palette intent.
    @IntentParameterDependency<CommandPaletteIntent>(\.$terminal)
    var commandPaletteIntent

    @MainActor
    func entities(for identifiers: [CommandEntity.ID]) async throws -> [CommandEntity] {
        // Extract unique terminal IDs to avoid fetching duplicates
        let terminalIds = Set(identifiers.map(\.terminalId))
        let terminals = try await TerminalEntity.defaultQuery.entities(for: Array(terminalIds))

        // Build a cache of terminals and their available commands
        // This avoids repeated command fetching for the same terminal
        typealias Tuple = (terminal: TerminalEntity, commands: [Ghostty.Command])
        let commandMap: [TerminalEntity.ID: Tuple] =
            terminals.reduce(into: [:]) { result, terminal in
                guard let commands = try? terminal.surfaceModel?.commands() else { return }
                result[terminal.id] = (terminal: terminal, commands: commands)
            }
        
        // Map each identifier to its corresponding CommandEntity. If a command doesn't
        // exist it maps to nil and is removed via compactMap.
        return identifiers.compactMap { id in
            guard let (terminal, commands) = commandMap[id.terminalId],
                  let command = commands.first(where: { $0.actionKey == id.actionKey }) else {
                return nil
            }

            return CommandEntity(command, for: terminal)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [CommandEntity] {
        guard let terminal = commandPaletteIntent?.terminal,
              let surface = terminal.surfaceModel else { return [] }
        return try surface.commands().map { CommandEntity($0, for: terminal) }
    }
}
