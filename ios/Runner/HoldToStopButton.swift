import UIKit

/// The always-available escape hatch: never disabled, since camera/sensor paths can
/// all fail. The long hold prevents sleep-mashing on the way to another challenge.
final class HoldToStopButton: UIButton {

    var onComplete: (() -> Void)?

    private let duration: TimeInterval
    private var timer: Timer?
    private var progressLayer: CAShapeLayer?
    private var startedAt: Date?
    private var didComplete = false

    private let trackColor = UIColor(white: 0.25, alpha: 1)

    init(title: String, duration: TimeInterval, tint: UIColor) {
        self.duration = duration
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
        progressLayer?.frame = bounds
        progressLayer?.cornerRadius = 14
    }

    @objc private func began() {
        startedAt = Date()
        titleLabel?.alpha = 0.85
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let fraction = min(1, elapsed / duration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer?.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width * fraction,
            height: bounds.height
        )
        CATransaction.commit()
        if fraction >= 1 {
            complete()
        }
    }

    @objc private func ended() {
        let heldLongEnough = startedAt
            .map { Date().timeIntervalSince($0) >= duration } ?? false
        reset()
        if heldLongEnough { complete() }
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        onComplete?()
        titleLabel?.alpha = 0.4
        isUserInteractionEnabled = false
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        titleLabel?.alpha = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer?.frame = bounds
        CATransaction.commit()
    }
}
