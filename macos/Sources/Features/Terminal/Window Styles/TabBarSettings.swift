import AppKit
import Combine

/// Appearance of the Ghostty X tab strip. Set from the Tab Bar settings window and stored
/// in the app's own defaults (not the Ghostty config), so changes apply live to every window.
struct TabBarSettings: Codable, Equatable {
    enum Position: String, Codable, CaseIterable, Identifiable {
        case top, bottom, left, right
        var id: Self { self }
        var isVertical: Bool { self == .left || self == .right }
        var title: String {
            switch self {
            case .top: "Top"
            case .bottom: "Bottom"
            case .left: "Left"
            case .right: "Right"
            }
        }
    }

    enum Style: String, Codable, CaseIterable, Identifiable {
        case filled, outline, minimal
        var id: Self { self }
        var title: String {
            switch self {
            case .filled: "Filled"
            case .outline: "Outline"
            case .minimal: "Minimal"
            }
        }
    }

    enum Width: String, Codable, CaseIterable, Identifiable {
        case fit, equal
        var id: Self { self }
        var title: String { self == .fit ? "Fit title" : "Equal" }
    }

    enum Alignment: String, Codable, CaseIterable, Identifiable {
        case leading, center
        var id: Self { self }
        var title: String { self == .leading ? "Leading" : "Centered" }
    }

    enum CloseButton: String, Codable, CaseIterable, Identifiable {
        case hover, always, never
        var id: Self { self }
        var title: String {
            switch self {
            case .hover: "On hover"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// Accent colors come from the active theme's palette so they always match it.
    enum Accent: String, Codable, CaseIterable, Identifiable {
        case blue, magenta, cyan, green, yellow, mono
        var id: Self { self }
        var title: String { rawValue.capitalized }
        /// Index into the 16-color palette, or nil for the foreground color.
        var paletteIndex: Int? {
            switch self {
            case .blue: 4
            case .magenta: 5
            case .cyan: 6
            case .green: 2
            case .yellow: 3
            case .mono: nil
            }
        }
    }

    enum TabColors: String, Codable, CaseIterable, Identifiable {
        case off, random
        var id: Self { self }
        var title: String { self == .off ? "Off" : "Random" }
    }

    /// How a tab's color (random, or picked by hand) is drawn on its capsule.
    enum ColorStyle: String, Codable, CaseIterable, Identifiable {
        case cap, tint, dot, both
        var id: Self { self }
        var title: String {
            switch self {
            case .cap: "Cap"
            case .tint: "Tint"
            case .dot: "Dot"
            case .both: "Both"
            }
        }
    }

    /// Theme palette entries random tab colors are drawn from: blue, magenta, cyan,
    /// green, yellow, red.
    static let randomPaletteIndices = [4, 5, 6, 2, 3, 1]

    static let heightRange: ClosedRange<Double> = 22...36
    static let spacingRange: ClosedRange<Double> = 2...14
    static let sidebarWidthRange: ClosedRange<Double> = 160...320

    var position: Position = .top
    var style: Style = .filled
    var width: Width = .fit
    var alignment: Alignment = .leading
    var closeButton: CloseButton = .hover
    var accent: Accent = .blue
    var tabHeight: Double = 28
    var spacing: Double = 6
    /// 0 is square corners, 1 is a full capsule.
    var roundness: Double = 1
    var sidebarWidth: Double = 200
    var showNumbers = true
    var showBackground = true
    var showWithSingleTab = true
    var tabColors: TabColors = .random
    var colorStyle: ColorStyle = .cap

    init() {}

    /// Corner radius for a capsule of the given height.
    func cornerRadius(height: CGFloat) -> CGFloat {
        height / 2 * CGFloat(min(max(roundness, 0), 1))
    }

    /// The bar's size across its main axis when it sits beside the terminal.
    var edgeThickness: CGFloat {
        position.isVertical ? CGFloat(sidebarWidth) : CGFloat(tabHeight) + 16
    }

    // Tolerate missing or unknown keys so older or newer saved values never reset everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = TabBarSettings()
        position = value(.position, d.position)
        style = value(.style, d.style)
        width = value(.width, d.width)
        alignment = value(.alignment, d.alignment)
        closeButton = value(.closeButton, d.closeButton)
        accent = value(.accent, d.accent)
        tabHeight = min(max(value(.tabHeight, d.tabHeight), Self.heightRange.lowerBound), Self.heightRange.upperBound)
        spacing = min(max(value(.spacing, d.spacing), Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
        roundness = min(max(value(.roundness, d.roundness), 0), 1)
        sidebarWidth = min(max(value(.sidebarWidth, d.sidebarWidth), Self.sidebarWidthRange.lowerBound),
                           Self.sidebarWidthRange.upperBound)
        showNumbers = value(.showNumbers, d.showNumbers)
        showBackground = value(.showBackground, d.showBackground)
        showWithSingleTab = value(.showWithSingleTab, d.showWithSingleTab)
        tabColors = value(.tabColors, d.tabColors)
        colorStyle = value(.colorStyle, d.colorStyle)
    }
}

/// Shared, persisted tab bar settings. Every tab strip and window subscribes to `$settings`.
@MainActor
final class TabBarSettingsStore: ObservableObject {
    static let shared = TabBarSettingsStore()
    static let defaultsKey = "GhosttyXTabBarSettings"

    @Published var settings: TabBarSettings {
        didSet { if settings != oldValue { save() } }
    }

    private let defaults: UserDefaults?

    /// Pass nil for an in-memory store (tests and previews).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(TabBarSettings.self, from: data) {
            settings = decoded
        } else {
            settings = TabBarSettings()
        }
    }

    func reset() { settings = TabBarSettings() }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
