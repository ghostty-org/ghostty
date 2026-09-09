import SwiftUI

public enum BrailleProgressStyle: Sendable {
    case spinner   // 1 char: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ (classic CLI spinner)
    case bar       // 4 chars: ⣀⣄⣤⣦ (equalizer / progress wave)
    case wave      // 4 chars: ⡀⠄⠂⠁ (traveling sine dot wave)
    case dots      // 3 chars: ⠋⠙⠚ (pulse)
    case circle    // 1 char: ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷
}

public struct BrailleProgressBarView: View {
    public var style: BrailleProgressStyle
    public var color: Color
    public var speed: Double
    public var fontSize: CGFloat
    public var fontWeight: Font.Weight
    public var isAnimating: Bool

    public init(
        style: BrailleProgressStyle = .bar,
        color: Color = .primary,
        speed: Double = 0.09,
        fontSize: CGFloat = 11,
        fontWeight: Font.Weight = .bold,
        isAnimating: Bool = true
    ) {
        self.style = style
        self.color = color
        self.speed = speed
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.isAnimating = isAnimating
    }

    public static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    public static let barFrames     = ["⣀⣄⣤⣦", "⣄⣤⣦⣶", "⣤⣦⣶⣷", "⣦⣶⣷⣿", "⣶⣷⣿⣷", "⣷⣿⣷⣶", "⣿⣷⣶⣦", "⣷⣶⣦⣤"]
    public static let waveFrames    = ["⡀⠄⠂⠁", "⠄⠂⠁⠈", "⠂⠁⠈⠐", "⠁⠈⠐⠠", "⠈⠐⠠⢀", "⠐⠠⢀⡀", "⠠⢀⡀⠄", "⢀⡀⠄⠂"]
    public static let circleFrames  = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
    public static let dotsFrames    = ["⠋⠙⠚", "⠙⠚⠞", "⠚⠞⠖", "⠞⠖⠦", "⠖⠦⠴", "⠦⠴⠲", "⠴⠲⠳", "⠲⠳⠓"]

    public var frames: [String] {
        switch style {
        case .spinner: return Self.spinnerFrames
        case .bar:     return Self.barFrames
        case .wave:    return Self.waveFrames
        case .circle:  return Self.circleFrames
        case .dots:    return Self.dotsFrames
        }
    }

    public var idleFrame: String {
        switch style {
        case .bar: return "⣀⣀⣀⣀"
        case .wave: return "⡀⡀⡀⡀"
        case .spinner, .circle: return "⠂"
        case .dots: return "⠤⠤⠤"
        }
    }

    public var body: some View {
        if isAnimating {
            TimelineView(.periodic(from: .now, by: speed)) { timeline in
                let idx = Int(timeline.date.timeIntervalSinceReferenceDate / speed)
                let frame = frames[abs(idx) % frames.count]
                Text(frame)
                    .font(.system(size: fontSize, weight: fontWeight, design: .monospaced))
                    .foregroundStyle(color)
            }
        } else {
            Text(idleFrame)
                .font(.system(size: fontSize, weight: fontWeight, design: .monospaced))
                .foregroundStyle(color.opacity(0.55))
        }
    }
}
