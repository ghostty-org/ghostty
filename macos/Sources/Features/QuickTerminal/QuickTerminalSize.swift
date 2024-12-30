import Cocoa
import GhosttyKit

class QuickTerminalSize {
    enum Size {
        case percent(value: Double)
        case pixel(value: UInt)
        
        init?(c_dimension: ghostty_config_quick_terminal_dimension_s) {
            switch(c_dimension.unit) {
            case GHOSTTY_QUICK_TERMINAL_PIXEL_UNIT:
                self = .pixel(value: UInt(c_dimension.value))
            case GHOSTTY_QUICK_TERMINAL_PERCENTAGE_UNIT:
                self = .percent(value: Double(c_dimension.value) / 100.0)
            default:
                return nil
            }
        }
        
        func apply(value: CGFloat) -> CGFloat {
            switch(self) {
            case .pixel(let fixed_size):
                return CGFloat(fixed_size);
            case .percent(let pct):
                return value * pct;
            }
        }
    }

    var mainDimension: Size;
    var secondDimension: Size;

    init() {
        self.mainDimension = Size.percent(value: 0.25)
        self.secondDimension = Size.percent(value: 0.25)
    }

    init(config: ghostty_config_quick_terminal_size_s) {
        switch (config.len) {
        case 1:
            self.mainDimension = Size(c_dimension: config.dimensions[0]) ?? Size.percent(value: 0.25)
            self.secondDimension = Size.percent(value: 0.25)
        case 2:
            self.mainDimension = Size(c_dimension: config.dimensions[0]) ?? Size.percent(value: 0.25)
            self.secondDimension = Size(c_dimension: config.dimensions[1]) ?? Size.percent(value: 0.25)
        default:
            self.mainDimension = Size.percent(value: 0.25)
            self.secondDimension = Size.percent(value: 0.25)
        }
    }
    
    /// Set the window size.
    func apply(_ window: NSWindow, _ position: QuickTerminalPosition) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        switch (position) {
        case .top, .bottom:
            window.setFrame(.init(
                origin: window.frame.origin,
                size: .init(
                    width: screen.frame.width,
                    height: self.mainDimension.apply(value: screen.frame.height))
            ), display: false)

        case .left, .right:
            window.setFrame(.init(
                origin: window.frame.origin,
                size: .init(
                    width: self.mainDimension.apply(value: screen.frame.width),
                    height: screen.frame.height)
            ), display: false)

        case .center:
            window.setFrame(.init(
                origin: window.frame.origin,
                size: .init(
                    width: self.mainDimension.apply(value: screen.frame.width),
                    height: self.secondDimension.apply(value: screen.frame.height))
            ), display: false)
        }
    }
}
