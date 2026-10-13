import UIKit

/// The always-available escape hatch: never disabled, since camera/sensor paths can
/// all fail. The long hold prevents sleep-mashing on the way to another challenge.
/// A brief lift keeps the progress earned so far; a full release restarts it.
final class HoldToStopButton: UIButton {

    var onComplete: (() -> Void)?

    private let duration: TimeInterval
    /// Held time already counted; survives a release for [grace].
    private var accumulated: TimeInterval = 0
    private var pressStarted: Date?
    private var graceDeadline: Date?
    private var timer: Timer?
    private var progressLayer: CAShapeLayer?
    private var didComplete = false
    private var lastTickSecond = -1
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let completionHaptic = UIImpactFeedbackGenerator(style: .medium)

    /// A lift shorter than this keeps the progress already earned.
    private let grace: TimeInterval = 1.0
    private let trackColor = UIColor(white: 0.25, alpha: 1)

    init(title: String, duration: TimeInterval, tint: UIColor) {
        self.duration = max(1, duration)
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        backgroundColor = trackColor
        layer.cornerRadius = 14
        layer.masksToBounds = true

        let layer = CAShapeLayer()
        layer.fillColor = tint.cgColor
        layer.strokeColor = nil
        layer.frame = bounds
        layer.cornerRadius = 14
        self.layer.addSublayer(layer)
        progressLayer = layer

        addTarget(self, action: #selector(began), for: .touchDown)
        addTarget(
            self,
            action: #selector(ended),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        accessibilityLabel = title
        accessibilityHint = NSLocalizedString("challenge.hold.hint", comment: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        progressLayer?.cornerRadius = 14
        setProgress(accumulated / duration)
    }

    /// Restarts the button after a rejected confirm tap, keeping it the way out.
    func reset() {
        timer?.invalidate()
        timer = nil
        didComplete = false
        isUserInteractionEnabled = true
        accumulated = 0
        pressStarted = nil
        graceDeadline = nil
        lastTickSecond = -1
        titleLabel?.alpha = 1
        setProgress(0)
    }

    @objc private func began() {
        guard !didComplete else { return }
        if accumulated > 0, let deadline = graceDeadline, Date() > deadline {
            accumulated = 0
        }
        pressStarted = Date()
        titleLabel?.alpha = 0.85
        impact.prepare()
        impact.impactOccurred()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let pressStarted else { return }
        let elapsed = accumulated + Date().timeIntervalSince(pressStarted)
        let fraction = min(1, elapsed / duration)
        setProgress(fraction)
        let second = Int(elapsed)
        if second != lastTickSecond {
            lastTickSecond = second
            impact.impactOccurred(intensity: 0.4)
        }
        if fraction >= 1 {
            complete()
        }
    }

    @objc private func ended() {
        timer?.invalidate()
        timer = nil
        if let started = pressStarted {
            accumulated += Date().timeIntervalSince(started)
        }
        pressStarted = nil
        graceDeadline = Date().addingTimeInterval(grace)
        setProgress(accumulated / duration)
        titleLabel?.alpha = 1
        if accumulated >= duration { complete() }
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        timer?.invalidate()
        timer = nil
        pressStarted = nil
        accumulated = duration
        setProgress(1)
        completionHaptic.impactOccurred()
        onComplete?()
    }

    private func setProgress(_ fraction: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let clamped = min(1, max(0, fraction))
        progressLayer?.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width * clamped,
            height: bounds.height
        )
        CATransaction.commit()
    }
}
