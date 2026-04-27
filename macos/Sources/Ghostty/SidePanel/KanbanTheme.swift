import SwiftUI

struct Theme {
    // MARK: - Light Theme
    struct Light {
        static let bgPrimary = Color(hex: "dcdcdc")
        static let bgSecondary = Color.white
        static let bgTertiary = Color(hex: "f9f9f9")
        static let textPrimary = Color(hex: "333333")
        static let textSecondary = Color(hex: "555555")
        static let textMuted = Color(hex: "888888")
        static let borderColor = Color.black.opacity(0.1)
        static let borderSubtle = Color.black.opacity(0.06)
        static let accent = Color(hex: "007aff")
        static let accentHover = Color(hex: "0064d9")
        static let danger = Color(hex: "ff3b30")
        static let success = Color(hex: "34c759")
        static let warning = Color(hex: "ff9500")
        static let worktree = Color(hex: "af52de")
        static let columnBg = Color.white
        static let taskBg = Color.white
        static let taskHoverBorder = Color.blue.opacity(0.3)
        static let inputBg = Color.white
        static let inputBorder = Color(hex: "d0d0d0")
        static let scrollbarThumb = Color(hex: "ccc")
        static let overlayBg = Color.black.opacity(0.4)
        static let headerGradientStart = Color(hex: "f9f9f9")
        static let headerGradientEnd = Color(hex: "e8e8e8")
        static let btnGradientStart = Color(hex: "fefefe")
        static let btnGradientEnd = Color(hex: "f0f0f0")
        static let modalBg = Color.white
        static let sessionPanelBg = Color(hex: "f9f9f9")
        static let modalFooterBg = Color(hex: "f9f9f9")
    }

    // MARK: - Dark Theme
    struct Dark {
        static let bgPrimary = Color(hex: "1e1e1e")
        static let bgSecondary = Color(hex: "252525")
        static let bgTertiary = Color(hex: "2d2d2d")
        static let textPrimary = Color(hex: "f0f0f0")
        static let textSecondary = Color(hex: "a0a0a0")
        static let textMuted = Color(hex: "666666")
        static let borderColor = Color.white.opacity(0.1)
        static let borderSubtle = Color.white.opacity(0.08)
        static let accent = Color(hex: "0a84ff")
        static let accentHover = Color(hex: "409cff")
        static let danger = Color(hex: "ff453a")
        static let success = Color(hex: "30d158")
        static let warning = Color(hex: "ff9f0a")
        static let worktree = Color(hex: "bf94ff")
        static let columnBg = Color(hex: "2d2d2d")
        static let taskBg = Color(hex: "333333")
        static let taskHoverBorder = Color.blue.opacity(0.4)
        static let inputBg = Color(hex: "1e1e1e")
        static let inputBorder = Color(hex: "404040")
        static let scrollbarThumb = Color(hex: "555")
        static let overlayBg = Color.black.opacity(0.6)
        static let headerGradientStart = Color(hex: "3a3a3a")
        static let headerGradientEnd = Color(hex: "2a2a2a")
        static let btnGradientStart = Color(hex: "4a4a4a")
        static let btnGradientEnd = Color(hex: "3a3a3a")
        static let modalBg = Color(hex: "2d2d2d")
        static let sessionPanelBg = Color(hex: "252525")
        static let modalFooterBg = Color(hex: "252525")
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Theme Environment

struct ThemeColors {
    let bgPrimary: Color
    let bgSecondary: Color
    let bgTertiary: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let borderColor: Color
    let borderSubtle: Color
    let accent: Color
    let accentHover: Color
    let danger: Color
    let success: Color
    let warning: Color
    let worktree: Color
    let columnBg: Color
    let taskBg: Color
    let taskHoverBorder: Color
    let inputBg: Color
    let inputBorder: Color
    let scrollbarThumb: Color
    let overlayBg: Color
    let headerGradientStart: Color
    let headerGradientEnd: Color
    let btnGradientStart: Color
    let btnGradientEnd: Color
    let modalBg: Color
    let sessionPanelBg: Color
    let modalFooterBg: Color

    static func colors(isDark: Bool) -> ThemeColors {
        isDark ? ThemeColors(
            bgPrimary: Theme.Dark.bgPrimary,
            bgSecondary: Theme.Dark.bgSecondary,
            bgTertiary: Theme.Dark.bgTertiary,
            textPrimary: Theme.Dark.textPrimary,
            textSecondary: Theme.Dark.textSecondary,
            textMuted: Theme.Dark.textMuted,
            borderColor: Theme.Dark.borderColor,
            borderSubtle: Theme.Dark.borderSubtle,
            accent: Theme.Dark.accent,
            accentHover: Theme.Dark.accentHover,
            danger: Theme.Dark.danger,
            success: Theme.Dark.success,
            warning: Theme.Dark.warning,
            worktree: Theme.Dark.worktree,
            columnBg: Theme.Dark.columnBg,
            taskBg: Theme.Dark.taskBg,
            taskHoverBorder: Theme.Dark.taskHoverBorder,
            inputBg: Theme.Dark.inputBg,
            inputBorder: Theme.Dark.inputBorder,
            scrollbarThumb: Theme.Dark.scrollbarThumb,
            overlayBg: Theme.Dark.overlayBg,
            headerGradientStart: Theme.Dark.headerGradientStart,
            headerGradientEnd: Theme.Dark.headerGradientEnd,
            btnGradientStart: Theme.Dark.btnGradientStart,
            btnGradientEnd: Theme.Dark.btnGradientEnd,
            modalBg: Theme.Dark.modalBg,
            sessionPanelBg: Theme.Dark.sessionPanelBg,
            modalFooterBg: Theme.Dark.modalFooterBg
        ) : ThemeColors(
            bgPrimary: Theme.Light.bgPrimary,
            bgSecondary: Theme.Light.bgSecondary,
            bgTertiary: Theme.Light.bgTertiary,
            textPrimary: Theme.Light.textPrimary,
            textSecondary: Theme.Light.textSecondary,
            textMuted: Theme.Light.textMuted,
            borderColor: Theme.Light.borderColor,
            borderSubtle: Theme.Light.borderSubtle,
            accent: Theme.Light.accent,
            accentHover: Theme.Light.accentHover,
            danger: Theme.Light.danger,
            success: Theme.Light.success,
            warning: Theme.Light.warning,
            worktree: Theme.Light.worktree,
            columnBg: Theme.Light.columnBg,
            taskBg: Theme.Light.taskBg,
            taskHoverBorder: Theme.Light.taskHoverBorder,
            inputBg: Theme.Light.inputBg,
            inputBorder: Theme.Light.inputBorder,
            scrollbarThumb: Theme.Light.scrollbarThumb,
            overlayBg: Theme.Light.overlayBg,
            headerGradientStart: Theme.Light.headerGradientStart,
            headerGradientEnd: Theme.Light.headerGradientEnd,
            btnGradientStart: Theme.Light.btnGradientStart,
            btnGradientEnd: Theme.Light.btnGradientEnd,
            modalBg: Theme.Light.modalBg,
            sessionPanelBg: Theme.Light.sessionPanelBg,
            modalFooterBg: Theme.Light.modalFooterBg
        )
    }
}

struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeColors.colors(isDark: false)
}

extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
