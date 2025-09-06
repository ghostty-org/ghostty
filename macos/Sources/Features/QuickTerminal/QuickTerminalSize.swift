import GhosttyKit

/// Represents the Ghostty `quick-terminal-size` configuration. See the documentation for
/// that for more details on exactly how it works. Some of those docs will be reproduced in various comments
/// in this file but that is the best source of truth for it.
///
/// The size determines the size of the quick terminal along the primary and secondary axis. The primary and
/// secondary axis is defined by the `quick-terminal-position`.
struct QuickTerminalSize {
    let primary: Size?
    let secondary: Size?

    init(primary: Size? = nil, secondary: Size? = nil) {
        self.primary = primary
        self.secondary = secondary
    }

    init(from cStruct: ghostty_config_quick_terminal_size_s) {
        self.primary = Size(from: cStruct.primary)
        self.secondary = Size(from: cStruct.secondary)
    }

    enum Size {
        case percentage(Float)
        case pixels(UInt32)

        init?(from cStruct: ghostty_quick_terminal_size_s) {
            switch cStruct.tag {
            case GHOSTTY_QUICK_TERMINAL_SIZE_NONE:
                return nil
            case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
                self = .percentage(cStruct.value.percentage)
            case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
                self = .pixels(cStruct.value.pixels)
            default:
                return nil
            }
        }

        func toPixels(parentDimension: CGFloat) -> CGFloat {
            switch self {
            case .percentage(let value):
                return parentDimension * CGFloat(value) / 100.0
            case .pixels(let value):
                return CGFloat(value)
            }
        }
    }


    /// This is an almost direct port of th Zig function QuickTerminalSize.calculate
    func calculate(position: QuickTerminalPosition, screenDimensions: CGSize) -> CGSize {
        let dims = CGSize(width: screenDimensions.width, height: screenDimensions.height)

        switch position {
        case .left, .right:
            return CGSize(
                width: primary?.toPixels(parentDimension: dims.width) ?? 400,
                height: secondary?.toPixels(parentDimension: dims.height) ?? dims.height
            )

        case .top, .bottom:
            return CGSize(
                width: secondary?.toPixels(parentDimension: dims.width) ?? dims.width,
                height: primary?.toPixels(parentDimension: dims.height) ?? 400
            )

        case .center:
            if dims.width >= dims.height {
                // Landscape
                return CGSize(
                    width: primary?.toPixels(parentDimension: dims.width) ?? 800,
                    height: secondary?.toPixels(parentDimension: dims.height) ?? 400
                )
            } else {
                // Portrait
                return CGSize(
                    width: secondary?.toPixels(parentDimension: dims.width) ?? 400,
                    height: primary?.toPixels(parentDimension: dims.height) ?? 800
                )
            }
        }
    }
}
