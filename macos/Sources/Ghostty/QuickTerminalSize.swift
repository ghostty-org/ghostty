import GhosttyKit

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
            switch cStruct.type {
            case GHOSTTY_QUICK_TERMINAL_SIZE_NONE:
                return nil
            case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
                let floatValue = withUnsafePointer(to: cStruct.value) { ptr in
                    ptr.withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
                }
                self = .percentage(floatValue)
            case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
                self = .pixels(cStruct.value)
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

    struct Dimensions {
        let width: CGFloat
        let height: CGFloat
    }

    func calculate(position: QuickTerminalPosition, screenDimensions: CGSize) -> Dimensions {
        let dims = Dimensions(width: screenDimensions.width, height: screenDimensions.height)

        switch position {
        case .left, .right:
            return Dimensions(
                width: primary?.toPixels(parentDimension: dims.width) ?? 400,
                height: secondary?.toPixels(parentDimension: dims.height) ?? dims.height
            )

        case .top, .bottom:
            return Dimensions(
                width: secondary?.toPixels(parentDimension: dims.width) ?? dims.width,
                height: primary?.toPixels(parentDimension: dims.height) ?? 400
            )

        case .center:
            if dims.width >= dims.height {
                // Landscape
                return Dimensions(
                    width: primary?.toPixels(parentDimension: dims.width) ?? 800,
                    height: secondary?.toPixels(parentDimension: dims.height) ?? 400
                )
            } else {
                // Portrait
                return Dimensions(
                    width: secondary?.toPixels(parentDimension: dims.width) ?? 400,
                    height: primary?.toPixels(parentDimension: dims.height) ?? 800
                )
            }
        }
    }
}
