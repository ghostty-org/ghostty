import SwiftUI

struct CommandOption: Identifiable, Hashable {
    /// Unique identifier for this option.
    let id = UUID()
    /// The primary text displayed for this command.
    let title: String
    /// Secondary text displayed below the title.
    let subtitle: String?
    /// Tooltip text shown on hover.
    let description: String?
    /// Keyboard shortcut symbols to display.
    let symbols: [String]?
    /// SF Symbol name for the leading icon.
    let leadingIcon: String?
    /// Color for the leading indicator circle.
    let leadingColor: Color?
    /// Badge text displayed as a pill.
    let badge: String?
    /// Whether to visually emphasize this option.
    let emphasis: Bool
    /// Sort key for stable ordering when titles are equal.
    let sortKey: ObjectIdentifier?
    /// The action to perform when this option is selected.
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        leadingColor: Color? = nil,
        badge: String? = nil,
        emphasis: Bool = false,
        sortKey: ObjectIdentifier? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.leadingColor = leadingColor
        self.badge = badge
        self.emphasis = emphasis
        self.sortKey = sortKey
        self.action = action
    }

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The overlay remains in its owning terminal window. AppKit owns search focus,
/// keyboard navigation, selection and reusable result rows inside this boundary.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [CommandOption]

    var body: some View {
        NativeCommandPalette(options: options) { option in
            isPresented = false
            option?.action()
        }
        .frame(maxWidth: 500)
        .frame(height: 248)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75)))
        .shadow(radius: 32, x: 0, y: 12)
        .padding()
        .environment(\.colorScheme, NSColor(backgroundColor).isLightColor ? .light : .dark)
    }
}

extension String {
    /// Returns the character indices that match `query`, trying a substring match first,
    /// then falling back to initials matching (first letter of each word).
    /// - Returns: `nil` if neither matches.
    func matchedIndices(for query: String) -> [String.Index]? {
        guard !query.isEmpty else { return nil }

        // Prefer substring match.
        if let range = self.range(of: query, options: .caseInsensitive) {
            return Array(self[range].indices)
        }

        // Fall back to initials match.
        let words = self.split(whereSeparator: \.isWhitespace)
        var queryIndex = query.startIndex
        var matched: [String.Index] = []

        for word in words {
            guard queryIndex < query.endIndex else { break }

            if word.first?.lowercased() == query[queryIndex].lowercased() {
                matched.append(word.startIndex)
                queryIndex = query.index(after: queryIndex)
            }
        }

        return queryIndex == query.endIndex ? matched : nil
    }
}

// MARK: - Match score

extension Collection where Element == CommandOption {
    /// Filters to the options matching `query` and ranks them best-first while
    /// maintaining original order: a closer leading color match always wins,
    /// then a title match beats a subtitle match beats a description match.
    func filteredAndSorted(query: String) -> [Element] {
        compactMap { CommandOptionMatch(option: $0, query: query) }
            .sorted {
                ($0.colorScore, $0.textScore) > ($1.colorScore, $1.textScore)
            }
            .map(\.option)
    }
}

/// A scored match of a command option against a palette query.
struct CommandOptionMatch {
    let option: CommandOption
    /// How closely the option's leading color matches a color name in the
    /// query, from 0 (no match) to 1 (exact).
    let colorScore: Double
    /// Which text field matched, ranked: title (3), subtitle (2),
    /// description (1), none (0).
    let textScore: Int

    /// Returns nil if the option doesn't match the query at all.
    init?(option: CommandOption, query: String) {
        let colorScore = Self.colorMatchScore(for: option.leadingColor, query: query)
        let textScore: Int = if option.title.matchedIndices(for: query) != nil {
            3
        } else if option.subtitle?.matchedIndices(for: query) != nil {
            2
        } else if option.description?.matchedIndices(for: query) != nil {
            1
        } else {
            0
        }

        guard colorScore > 0 || textScore > 0 else { return nil }
        self.option = option
        self.colorScore = colorScore
        self.textScore = textScore
    }

    /// Returns a score (0.0 to 1.0) indicating how well a color matches a search query color name.
    /// Returns 0 if no color name in the query matches, or if the color is nil.
    static func colorMatchScore(for color: Color?, query: String) -> Double {
        guard let color = color else { return 0 }

        let queryLower = query.lowercased()
        let nsColor = NSColor(color)

        var bestScore: Double = 0
        for name in NSColor.colorNames {
            guard queryLower.contains(name),
                  let systemColor = NSColor(named: name) else { continue }

            let distance = nsColor.distance(to: systemColor)
            // Max distance in weighted RGB space is ~3.0, so normalize and invert
            // Use a threshold to determine "close enough" matches
            let maxDistance: Double = 1.5
            if distance < maxDistance {
                let score = 1.0 - (distance / maxDistance)
                bestScore = max(bestScore, score)
            }
        }

        return bestScore
    }
}
