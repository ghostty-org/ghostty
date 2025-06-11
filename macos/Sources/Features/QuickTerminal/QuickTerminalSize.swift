import Cocoa
import GhosttyKit

struct QuickTerminalSize {
    let primary: Size?
    let secondary: Size?
    
    init(primary: Size? = nil, secondary: Size? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
    
    init(from cStruct: ghostty_config_quick_terminal_size_s) {
        self.primary = cStruct.primary_type == 0 ? nil : Size(type: cStruct.primary_type, value: cStruct.primary_value)
        self.secondary = cStruct.secondary_type == 0 ? nil : Size(type: cStruct.secondary_type, value: cStruct.secondary_value)
    }
    
    enum Size {
        case percentage(Float)
        case pixels(UInt32)
        
        init?(type: UInt8, value: Float) {
            switch type {
            case 1:
                self = .percentage(value)
            case 2:
                self = .pixels(UInt32(value))
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