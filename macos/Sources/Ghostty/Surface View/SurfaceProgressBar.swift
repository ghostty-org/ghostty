import AppKit

/// The progress bar to show a surface progress report. We implement this from scratch because the
/// standard ProgressView is broken on macOS 26 and this is simple anyways and gives us a ton of
/// control.
///
/// A 2px sibling of the scroll view (not a Metal overlay) so WindowServer does
/// not composite the terminal. Uses this view's own layer.
final class SurfaceProgressBar: NSView {
    static let hairlineHeight: CGFloat = 2

    private var report: Ghostty.Action.ProgressReport?
    private var timer: Timer?
    private var pulse = PulsingProgressBar()

    private var color: NSColor {
        guard let report else { return .controlAccentColor }
        switch report.state {
        case .error: return .systemRed
        case .pause: return .systemOrange
        default: return .controlAccentColor
        }
    }

    private var progress: UInt8? {
        guard let report else { return nil }
        // If we have an explicit progress use that.
        if let v = report.progress { return v }

        // Otherwise, if we're in the pause state, we act as if we're at 100%.
        if report.state == .pause { return 100 }

        return nil
    }

    private var accessibilityLabel: String {
        guard let report else { return "Terminal progress" }
        switch report.state {
        case .error: return "Terminal progress - Error"
        case .pause: return "Terminal progress - Paused"
        case .indeterminate: return "Terminal progress - In progress"
        default: return "Terminal progress"
        }
    }

    private var accessibilityValue: String {
        if let progress {
            return "\(progress) percent complete"
        } else {
            guard let report else { return "Indeterminate progress" }
            switch report.state {
            case .error: return "Operation failed"
            case .pause: return "Operation paused at completion"
            case .indeterminate: return "Operation in progress"
            default: return "Indeterminate progress"
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityHidden(true)
        // VoiceOver polls AXUpdatesFrequently instead of waiting on notifications.
        _ = accessibilitySetOverrideValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXUpdatesFrequently"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        timer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func setReport(_ report: Ghostty.Action.ProgressReport?) {
        guard let report, report.state != .remove else {
            self.report = nil
            stopPulse()
            isHidden = true
            setAccessibilityHidden(true)
            return
        }

        self.report = report
        isHidden = false
        setAccessibilityHidden(false)
        if let superview {
            layoutHairline(in: superview.bounds)
        } else {
            applyAppearance()
        }
    }

    /// Parent passes the surface bounds. Determinate shrinks width to the
    /// percentage; indeterminate keeps the full width.
    func layoutHairline(in container: NSRect) {
        let y = container.height - Self.hairlineHeight
        var width = container.width
        if let progress {
            width = container.width * CGFloat(progress) / 100
        }
        frame = CGRect(x: 0, y: y, width: width, height: Self.hairlineHeight)
        applyAppearance()
    }

    private func applyAppearance() {
        guard report != nil, !isHidden else { return }
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(accessibilityValue)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if progress == nil {
            layer?.backgroundColor = cgColor(color.withAlphaComponent(pulse.alpha))
            CATransaction.commit()
            if timer == nil {
                startPulse()
            }
        } else {
            stopPulse()
            layer?.backgroundColor = cgColor(color)
            CATransaction.commit()
        }
    }

    private func startPulse() {
        timer?.invalidate()
        timer = nil
        pulse.reset()
        applyPulseColor()
        let timer = Timer(timeInterval: PulsingProgressBar.interval, repeats: true) { [weak self] _ in
            self?.stepPulse()
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPulse() {
        timer?.invalidate()
        timer = nil
        layer?.removeAllAnimations()
    }

    private func stepPulse() {
        pulse.step()
        applyPulseColor()
    }

    private func applyPulseColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = cgColor(color.withAlphaComponent(pulse.alpha))
        CATransaction.commit()
    }

    private func cgColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}

/// Indeterminate full-width opacity pulse, 24 levels at 12 Hz.
private struct PulsingProgressBar {
    static let hz: Double = 12
    static let steps: Int = 24
    static let alphaOn: CGFloat = 1.0
    static let alphaOff: CGFloat = 0.35
    static var interval: TimeInterval { 1.0 / hz }

    var tick: Int = 0

    mutating func reset() {
        tick = Self.steps - 1
    }

    mutating func step() {
        tick += 1
    }

    var alpha: CGFloat {
        let n = Self.steps - 1
        let period = 2 * n
        let i = tick % period
        let step = i <= n ? i : period - i
        let t = CGFloat(step) / CGFloat(n)
        return Self.alphaOff + (Self.alphaOn - Self.alphaOff) * t
    }
}
