import AVFoundation
import UIKit
import Vision

/// Native iOS wake challenge, kept out of Flutter so dismissing a live alarm
/// never depends on the Dart isolate; Vision/AVFoundation add zero dependencies.
final class WakeChallengeViewController: UIViewController {

    private enum Mode: Hashable { case face, typed, qr }

    private let alarm: StoredAlarm
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.wakeguard.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var mode: Mode = .face
    private var actions: [WakeAction] = []
    private var actionIndex = 0
    private var challengeComplete = false
    private var successCountdownTimer: Timer?
    private var successCountdownLabel: UILabel?
    private var successCloseDeadline: TimeInterval?

    private let answerField = UITextField()
    private let instructionLabel = UILabel()
    private let statusLabel = UILabel()
    private let stepLabel = UILabel()
    private let hintLabel = UILabel()
    private let challengeProgress = UIProgressView(progressViewStyle: .default)
    private let previewContainer = UIView()
    private let brightnessControls = UIStackView()
    private let brightnessContainer = UIView()
    private let brightnessLabel = UILabel()
    private let brightnessSlider = UISlider()
    private let typedControls = UIStackView()
    private let typedContainer = UIView()
    private var modeButtons: [Mode: UIButton] = [:]
    private var holdButton: HoldToStopButton?
    private var confirmOverlay: UIView?
    private var faceBrightness: CGFloat?
    private var previousBrightness: CGFloat?
    private var previousIdleTimerDisabled = false
    private var analysisGeneration = 0

    private let accent = UIColor(red: 1, green: 0.61, blue: 0.44, alpha: 1)
    private let surface = UIColor(white: 0.13, alpha: 1)

    private var lastAnalysis = Date.distantPast
    private var cameraUnavailable = false

    // Face action state machine.
    private var eyesWereClosed = false
    private var typedAnswer = 0
    private var blinkCount = 0
    private var holdStartedAt: Date?

    private static let analysisInterval: TimeInterval = 0.12
    private static let successCloseDelay: TimeInterval = 5
    // The last-resort escape is intentionally long; its length is per-alarm
    // (StoredAlarm.effectiveHoldSeconds), defaulting to 60.
    private var holdTitle: String {
        let seconds = alarm.effectiveHoldSeconds
        return seconds >= 60
            ? String(format: NSLocalizedString("challenge.hold.minutes", comment: ""), seconds / 60)
            : String(format: NSLocalizedString("challenge.hold.seconds", comment: ""), seconds)
    }

    init(alarm: StoredAlarm) {
        self.alarm = alarm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        actions = Self.pickActions(count: alarm.stepCount)
        view.backgroundColor = UIColor(white: 0.065, alpha: 1)
        buildLayout()
        updateInstructions()
        updateModeAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(restoreBrightness), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeBrightness), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !challengeComplete else { return }
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        applyFaceBrightness()
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        successCountdownTimer?.invalidate()
        restoreBrightness()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        analysisGeneration += 1
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewContainer.bounds
    }

    // MARK: - Layout

    private func buildLayout() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        content.addArrangedSubview(label("WAKEGUARD · TIME TO WAKE UP", size: 12, color: accent))
        content.addArrangedSubview(label(alarm.label, size: 24, color: .white))
        instructionLabel.textColor = .white
        instructionLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 28, weight: .bold))
        instructionLabel.adjustsFontForContentSizeCategory = true
        instructionLabel.numberOfLines = 0
        instructionLabel.textAlignment = .center

        stepLabel.textColor = .lightGray
        stepLabel.font = .systemFont(ofSize: 14)
        stepLabel.textAlignment = .center
        stepLabel.numberOfLines = 0
        stepLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = .lightGray
        hintLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        challengeProgress.progressTintColor = accent
        challengeProgress.trackTintColor = UIColor(white: 0.24, alpha: 1)

        statusLabel.textColor = UIColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            instructionLabel,
            stepLabel,
            challengeProgress,
            hintLabel,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.backgroundColor = surface
        stack.layer.cornerRadius = 20
        content.addArrangedSubview(stack)

        previewContainer.layer.cornerRadius = 20
        previewContainer.clipsToBounds = true
        previewContainer.backgroundColor = .black
        content.addArrangedSubview(previewContainer)
        let previewHeight = previewContainer.heightAnchor.constraint(equalTo: previewContainer.widthAnchor, multiplier: 0.85)
        previewHeight.priority = .defaultHigh
        previewHeight.isActive = true

        buildBrightnessControls()
        pinStack(brightnessControls, in: brightnessContainer)
        content.addArrangedSubview(brightnessContainer)

        let modeRow = UIStackView()
        modeRow.axis = .horizontal
        modeRow.distribution = .fillEqually
        modeRow.spacing = 8
        modeRow.addArrangedSubview(modeButton("Face", .face))
        modeRow.addArrangedSubview(modeButton("Type", .typed))
        if !alarm.qrValue.isEmpty {
            modeRow.addArrangedSubview(modeButton("QR", .qr))
        }
        content.addArrangedSubview(modeRow)

        answerField.keyboardType = .numberPad
        answerField.textColor = .white
        answerField.textAlignment = .center
        answerField.font = .systemFont(ofSize: 26)
        answerField.backgroundColor = UIColor(white: 0.15, alpha: 1)
        answerField.layer.cornerRadius = 10
        answerField.accessibilityLabel = NSLocalizedString("challenge.answer.label", comment: "")
        typedControls.axis = .vertical
        typedControls.spacing = 8
        typedContainer.isHidden = true
        typedControls.addArrangedSubview(answerField)
        let answerHeight = answerField.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        answerHeight.priority = .defaultHigh
        answerHeight.isActive = true

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle(NSLocalizedString("challenge.confirm", comment: ""), for: .normal)
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1)
        confirmButton.layer.cornerRadius = 12
        confirmButton.addTarget(self, action: #selector(confirmTypedAnswer), for: .touchUpInside)
        typedControls.addArrangedSubview(confirmButton)
        let confirmHeight = confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        confirmHeight.priority = .defaultHigh
        confirmHeight.isActive = true
        pinStack(typedControls, in: typedContainer)
        content.addArrangedSubview(typedContainer)

        content.addArrangedSubview(label("Need another way?", size: 14, color: .lightGray))
        let holdButton = HoldToStopButton(
            title: holdTitle,
            duration: TimeInterval(alarm.effectiveHoldSeconds),
            tint: UIColor(red: 0.72, green: 0.11, blue: 0.11, alpha: 1)
        )
        holdButton.onComplete = { [weak self] in self?.showConfirmStep() }
        self.holdButton = holdButton
        content.addArrangedSubview(holdButton)
        holdButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        content.addArrangedSubview(label(NSLocalizedString("challenge.hold.body", comment: ""), size: 12, color: .lightGray))
    }

    private func label(_ text: String, size: CGFloat, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = color
        return label
    }

    /// Hide the wrapper rather than collapsing a nested stack's required spacing.
    private func pinStack(_ stack: UIStackView, in container: UIView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottom,
        ])
    }

    private func buildBrightnessControls() {
        brightnessControls.axis = .vertical
        brightnessControls.spacing = 8
        brightnessControls.isLayoutMarginsRelativeArrangement = true
        brightnessControls.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        brightnessControls.backgroundColor = surface
        brightnessControls.layer.cornerRadius = 20
        brightnessLabel.textColor = .white
        brightnessLabel.numberOfLines = 0
        brightnessLabel.textAlignment = .center
        brightnessLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        brightnessLabel.adjustsFontForContentSizeCategory = true
        brightnessLabel.text = NSLocalizedString("challenge.brightness.system", comment: "")
        brightnessControls.addArrangedSubview(brightnessLabel)
        brightnessSlider.minimumValue = 0.1
        brightnessSlider.maximumValue = 1
        brightnessSlider.value = Float(UIScreen.main.brightness)
        brightnessSlider.tintColor = accent
        brightnessSlider.accessibilityLabel = NSLocalizedString("challenge.brightness", comment: "")
        brightnessSlider.addTarget(self, action: #selector(brightnessChanged), for: .valueChanged)
        brightnessControls.addArrangedSubview(brightnessSlider)
        brightnessControls.addArrangedSubview(label(NSLocalizedString("challenge.brightness.hint", comment: ""), size: 12, color: .lightGray))
        let reset = UIButton(type: .system)
        reset.setTitle(NSLocalizedString("challenge.brightness.reset", comment: ""), for: .normal)
        reset.tintColor = accent
        let resetHeight = reset.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        resetHeight.priority = .defaultHigh
        resetHeight.isActive = true
        reset.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            faceBrightness = nil
            restoreBrightness()
            brightnessSlider.value = Float(UIScreen.main.brightness)
            brightnessLabel.text = NSLocalizedString("challenge.brightness.system", comment: "")
        }, for: .touchUpInside)
        brightnessControls.addArrangedSubview(reset)
    }

    @objc private func brightnessChanged() {
        faceBrightness = CGFloat(brightnessSlider.value)
        brightnessLabel.text = String(format: NSLocalizedString("challenge.brightness.percent", comment: ""), Int(brightnessSlider.value * 100))
        applyFaceBrightness()
    }

    private func applyFaceBrightness() {
        guard mode == .face, let value = faceBrightness else {
            restoreBrightness()
            return
        }
        if previousBrightness == nil { previousBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = value
    }

    @objc private func restoreBrightness() {
        guard let previousBrightness else { return }
        UIScreen.main.brightness = previousBrightness
        self.previousBrightness = nil
    }

    @objc private func resumeBrightness() {
        if view.window != nil { applyFaceBrightness() }
    }

    private func modeButton(_ title: String, _ target: Mode) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 0.2, alpha: 1)
        button.layer.cornerRadius = 10
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        button.addAction(
            UIAction { [weak self] _ in self?.setMode(target) },
            for: .touchUpInside
        )
        modeButtons[target] = button
        return button
    }

    // MARK: - Mode

    private func setMode(_ next: Mode) {
        analysisGeneration += 1
        mode = next
        holdStartedAt = nil
        eyesWereClosed = false
        blinkCount = 0
        let typing = next == .typed
        typedContainer.isHidden = !typing
        previewContainer.isHidden = typing
        brightnessContainer.isHidden = next != .face
        if !typing { view.endEditing(true) }
        applyFaceBrightness()
        updateModeAppearance()
        if typing {
            rollTypedChallenge()
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }
        if !typing {
            refitCameraInput(position(for: next))
            startSession()
        }
        setStatus("")
        updateInstructions()
    }

    private func updateModeAppearance() {
        for (target, button) in modeButtons {
            let selected = target == mode
            button.isSelected = selected
            button.backgroundColor = selected ? accent : surface
            button.setTitleColor(selected ? .black : .white, for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func rollTypedChallenge() {
        let challenge = Challenge.make()
        typedAnswer = challenge.answer
        answerField.placeholder = challenge.prompt
        answerField.text = nil
    }

    @objc private func confirmTypedAnswer() {
        guard let text = answerField.text, !text.isEmpty else {
            setStatus(NSLocalizedString("challenge.enter_first", comment: ""))
            return
        }
        if Challenge.matches(input: text, answer: typedAnswer) {
            complete(method: "typed")
        } else {
            rollTypedChallenge()
            setStatus(NSLocalizedString("challenge.not_quite", comment: ""))
        }
    }

    private func updateInstructions() {
        previewContainer.isHidden = mode == .typed || cameraUnavailable
        brightnessContainer.isHidden = mode != .face || cameraUnavailable
        challengeProgress.isHidden = mode != .face || cameraUnavailable
        challengeProgress.progress = actions.isEmpty ? 0 : Float(actionIndex) / Float(actions.count)
        switch mode {
        case .face:
            hintLabel.text = actions.indices.contains(actionIndex)
                ? actions[actionIndex].hint
                : NSLocalizedString("challenge.face.hint", comment: "")
        case .typed:
            hintLabel.text = "Solve the question, then tap Confirm."
        case .qr:
            hintLabel.text = "Point the rear camera at the whole code. Hold steady in good light; scanning is automatic."
        }
        switch mode {
        case .face:
            if cameraUnavailable {
                instructionLabel.text = NSLocalizedString("challenge.camera_unavailable", comment: "")
                stepLabel.text = NSLocalizedString("challenge.use_type", comment: "")
                return
            }
            guard !actions.isEmpty else { return }
            let action = actions[min(actionIndex, actions.count - 1)]
            instructionLabel.text = action.instruction
            stepLabel.text = String(
                format: NSLocalizedString("challenge.step", comment: ""),
                actionIndex + 1,
                actions.count
            )

        case .typed:
            instructionLabel.text = NSLocalizedString("challenge.type_instruction", comment: "")
            stepLabel.text = NSLocalizedString("challenge.no_camera", comment: "")

        case .qr:
            instructionLabel.text = NSLocalizedString("challenge.qr_instruction", comment: "")
            stepLabel.text = NSLocalizedString("challenge.get_up", comment: "")
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            guard self.statusLabel.text != text else { return }
            self.statusLabel.text = text
            self.statusLabel.isHidden = text.isEmpty
        }
    }

    // MARK: - Capture

    /// QR needs the rear camera: a card cannot be scanned by the selfie lens.
    private func position(for selectedMode: Mode) -> AVCaptureDevice.Position {
        selectedMode == .qr ? .back : .front
    }

    /// Swaps to the requested lens, removing the old input so cameras cannot stack.
    private func refitCameraInput(_ wanted: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard mode != .typed, wanted == position(for: mode), !session.inputs.isEmpty else { return }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: wanted
            ),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                markCameraUnavailable()
                return
            }
            configureVideoConnection()
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.cameraUnavailable = false
                self.updatePreviewConnection()
                self.updateInstructions()
            }
        }
    }

    private func startSession() {
        guard mode != .typed else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                granted ? self?.configureSession() : self?.markCameraUnavailable()
            }
        default:
            markCameraUnavailable()
        }
    }

    private func markCameraUnavailable() {
        DispatchQueue.main.async {
            self.cameraUnavailable = true
            self.setStatus(NSLocalizedString("challenge.camera_denied", comment: ""))
            self.updateInstructions()
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard mode != .typed else { return }
            if !session.inputs.isEmpty {
                if !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high

            let initialPosition = position(for: mode)
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: initialPosition),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                markCameraUnavailable()
                return
            }
            session.addInput(input)

            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            configureVideoConnection()

            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.metadataObjectTypes = [.qr]
            }

            session.commitConfiguration()
            session.startRunning()

            DispatchQueue.main.async {
                self.cameraUnavailable = false
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.previewContainer.bounds
                self.previewLayer?.removeFromSuperlayer()
                self.previewContainer.layer.insertSublayer(layer, at: 0)
                self.previewLayer = layer
                self.updatePreviewConnection()
                self.updateInstructions()
            }
        }
    }

    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // Keep recognition frames unmirrored so left/right yaw stays consistent.
            connection.isVideoMirrored = false
        }
    }

    private func updatePreviewConnection() {
        guard let connection = previewLayer?.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // Mirror the selfie display only; QR uses the normal rear-camera view.
            connection.isVideoMirrored = mode == .face
        }
    }

    // MARK: - Completion

    /// Deliberate second gesture after a finished hold: a randomly placed button so
    /// a blind double-tap cannot stop a live alarm. Anywhere else restarts the hold.
    private func showConfirmStep() {
        guard confirmOverlay == nil, !challengeComplete else { return }
        let overlay = UIView()
        overlay.backgroundColor = UIColor(white: 0.04, alpha: 0.97)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.accessibilityViewIsModal = true
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A full-screen target behind everything catches any tap that is not the button.
        let wrongTarget = UIButton(type: .custom)
        wrongTarget.addTarget(self, action: #selector(onWrongHoldSpot), for: .touchUpInside)
        wrongTarget.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(wrongTarget)
        NSLayoutConstraint.activate([
            wrongTarget.topAnchor.constraint(equalTo: overlay.topAnchor),
            wrongTarget.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            wrongTarget.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            wrongTarget.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])

        let column = UIStackView(arrangedSubviews: [
            label("HOLD COMPLETE", size: 13, color: accent),
            label(NSLocalizedString("challenge.hold.confirm.title", comment: ""), size: 28, color: .white),
            label(NSLocalizedString("challenge.hold.confirm.body", comment: ""), size: 14, color: .lightGray),
        ])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 64),
            column.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
        ])

        let stop = UIButton(type: .system)
        stop.setTitle(NSLocalizedString("challenge.hold.confirm.button", comment: ""), for: .normal)
        stop.setTitleColor(.black, for: .normal)
        stop.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        stop.backgroundColor = accent
        stop.layer.cornerRadius = 14
        stop.contentEdgeInsets = UIEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        stop.addTarget(self, action: #selector(stopFromConfirmStep), for: .touchUpInside)
        stop.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stop)

        // Random position: the same spot twice in a row becomes a memorised macro,
        // so drop the button anywhere in the lower area outside the header copy.
        let pad: CGFloat = 24
        let header: CGFloat = 220
        let intrinsic = stop.intrinsicContentSize
        let buttonWidth = max(intrinsic.width, 160)
        let buttonHeight = max(intrinsic.height, 52)
        let insets = view.safeAreaInsets
        let minY = insets.top + header
        let maxY = max(view.bounds.height - insets.bottom - buttonHeight - pad, minY)
        let maxX = max(view.bounds.width - buttonWidth - pad, pad)
        let x = CGFloat.random(in: pad...maxX)
        let y = CGFloat.random(in: minY...maxY)
        NSLayoutConstraint.activate([
            stop.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            stop.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: x),
            stop.topAnchor.constraint(equalTo: overlay.topAnchor, constant: y),
        ])

        confirmOverlay = overlay
    }

    @objc private func stopFromConfirmStep() {
        complete(method: "hold")
    }

    @objc private func onWrongHoldSpot() {
        confirmOverlay?.removeFromSuperview()
        confirmOverlay = nil
        holdButton?.reset()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func complete(method: String) {
        guard !challengeComplete else { return }
        challengeComplete = true
        confirmOverlay?.removeFromSuperview()
        confirmOverlay = nil
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        restoreBrightness()
        AlarmActionHandler.shared.dismissFromChallenge(alarmId: alarm.id, method: method)
        showSuccess()
        startSuccessCountdown()
    }

    private func startSuccessCountdown() {
        successCountdownTimer?.invalidate()
        successCloseDeadline = ProcessInfo.processInfo.systemUptime + Self.successCloseDelay
        updateSuccessCountdown()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.updateSuccessCountdown()
        }
        successCountdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateSuccessCountdown() {
        guard let deadline = successCloseDeadline else { return }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            successCountdownTimer?.invalidate()
            dismiss(animated: true)
            return
        }
        let seconds = Int(ceil(remaining))
        let key = seconds == 1 ? "challenge.success.auto_close.one" : "challenge.success.auto_close"
        successCountdownLabel?.text = String(format: NSLocalizedString(key, comment: ""), seconds)
    }

    private func showSuccess() {
        view.endEditing(true)
        view.subviews.forEach { $0.removeFromSuperview() }
        let successColor = UIColor(red: 0.56, green: 0.88, blue: 0.70, alpha: 1)
        let scroll = UIScrollView()
        let content = UIView()
        let card = UIStackView()
        card.axis = .vertical
        card.alignment = .fill
        card.spacing = 16
        card.backgroundColor = surface
        card.layer.cornerRadius = 28
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 32, left: 24, bottom: 28, right: 24)
        for item in [scroll, content, card] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(scroll)
        scroll.addSubview(content)
        content.addSubview(card)
        let preferredWidth = card.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            card.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 32),
            card.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            card.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48),
            preferredWidth,
        ])
        func successLabel(_ key: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
            let result = UILabel()
            result.text = NSLocalizedString(key, comment: "")
            result.font = .preferredFont(forTextStyle: style)
            result.adjustsFontForContentSizeCategory = true
            result.textColor = color
            result.textAlignment = .center
            result.numberOfLines = 0
            return result
        }
        card.addArrangedSubview(successLabel("challenge.success.badge", style: .caption1, color: successColor))
        let iconContainer = UIView()
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = successColor
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            iconContainer.heightAnchor.constraint(equalToConstant: 88),
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])
        card.addArrangedSubview(iconContainer)
        let title = successLabel("challenge.success.title", style: .largeTitle, color: .white)
        title.accessibilityTraits.insert(.header)
        card.addArrangedSubview(title)
        card.addArrangedSubview(successLabel("challenge.success.detail", style: .body, color: .lightGray))
        if let quote = MotivationalQuotes.shared.next() {
            let quoteCard = UIStackView()
            quoteCard.axis = .vertical
            quoteCard.isLayoutMarginsRelativeArrangement = true
            quoteCard.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            quoteCard.backgroundColor = UIColor(red: 0.10, green: 0.22, blue: 0.17, alpha: 1)
            quoteCard.layer.cornerRadius = 16
            let quoteLabel = UILabel()
            quoteLabel.text = "“\(quote)”"
            quoteLabel.font = .preferredFont(forTextStyle: .title3)
            quoteLabel.adjustsFontForContentSizeCategory = true
            quoteLabel.numberOfLines = 0
            quoteLabel.textAlignment = .center
            quoteLabel.textColor = successColor
            quoteCard.addArrangedSubview(quoteLabel)
            card.addArrangedSubview(quoteCard)
        }
        let close = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("challenge.success.close", comment: "")
        configuration.baseBackgroundColor = accent
        configuration.baseForegroundColor = .black
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        close.configuration = configuration
        close.addAction(UIAction { [weak self] _ in
            self?.successCountdownTimer?.invalidate()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        card.addArrangedSubview(close)
        let countdownLabel = successLabel("challenge.success.auto_close", style: .caption1, color: .lightGray)
        countdownLabel.text = nil
        successCountdownLabel = countdownLabel
        card.addArrangedSubview(countdownLabel)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .screenChanged, argument: title)
        if !UIAccessibility.isReduceMotionEnabled {
            card.alpha = 0
            card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            UIView.animate(withDuration: 0.22) { card.alpha = 1; card.transform = .identity }
        }
    }

    /// Random subset, always including real head/eye movement so it can't pass from bed.
    private static func pickActions(count: Int) -> [WakeAction] {
        var picked = Array(WakeAction.allCases.shuffled().prefix(max(1, min(count, WakeAction.allCases.count))))
        if picked.allSatisfy({ $0 == .holdEyesOpen }), let last = picked.indices.last {
            picked[last] = .turnLeft
        }
        return picked
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension WakeChallengeViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !challengeComplete else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) > Self.analysisInterval else { return }
        lastAnalysis = now

        guard mode == .face, !cameraUnavailable else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let generation = analysisGeneration

        let request = VNDetectFaceLandmarksRequest { [weak self] request, _ in
            guard let self else { return }
            let observations = (request.results as? [VNFaceObservation]) ?? []
            DispatchQueue.main.async {
                guard !self.challengeComplete, self.mode == .face, generation == self.analysisGeneration else { return }
                guard observations.count == 1, let observation = observations.first else {
                    self.holdStartedAt = nil
                    self.eyesWereClosed = false
                    self.setStatus(NSLocalizedString(observations.isEmpty ? "challenge.no_face" : "challenge.multiple_faces", comment: ""))
                    return
                }
                self.evaluate(observation)
            }
        }
        request.revision = VNDetectFaceLandmarksRequestRevision3

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            // The output connection supplies upright portrait, unmirrored frames.
            orientation: .up,
            options: [:]
        )
        try? handler.perform([request])
    }

    private func evaluate(_ face: VNFaceObservation) {
        guard !challengeComplete, mode == .face, !actions.isEmpty else { return }
        let action = actions[min(actionIndex, actions.count - 1)]
        let landmarks = face.landmarks

        var passed = false
        switch action {
        case .blinkTwice:
            guard let aperture = Self.eyeAperture(landmarks) else {
                eyesWereClosed = false
                setStatus("Look straight at the camera so your eyes are visible")
                return
            }
            if aperture < 0.28 { eyesWereClosed = true }
            if eyesWereClosed && aperture > 0.62 {
                blinkCount += 1
                eyesWereClosed = false
                passed = blinkCount >= 2
            }
            setStatus("\(blinkCount) of 2 blinks")

        case .smile:
            setStatus("Face found · Give a clear smile")
            passed = Self.smileScore(landmarks) > 0.6

        case .turnLeft:
            setStatus("Face found · Turn to your left")
            passed = Self.headYaw(face) > 0.38
        case .turnRight:
            setStatus("Face found · Turn to your right")
            passed = Self.headYaw(face) < -0.38

        case .holdEyesOpen:
            guard let aperture = Self.eyeAperture(landmarks) else {
                holdStartedAt = nil
                setStatus("Look straight at the camera so your eyes are visible")
                return
            }
            if aperture > 0.55 {
                if holdStartedAt == nil { holdStartedAt = Date() }
                let held = Date().timeIntervalSince(holdStartedAt!)
                setStatus(String(
                    format: NSLocalizedString("challenge.keep_open", comment: ""),
                    max(0, 5 - Int(held))
                ))
                passed = held >= 5
            } else {
                holdStartedAt = nil
                setStatus("Open both eyes to start the 5-second check")
            }
        }

        guard passed else { return }
        actionIndex += 1
        blinkCount = 0
        eyesWereClosed = false
        holdStartedAt = nil
        if actionIndex >= actions.count {
            complete(method: "face")
        } else {
            DispatchQueue.main.async {
                self.setStatus("")
                self.updateInstructions()
            }
        }
    }

    /// Head yaw in radians; `VNFaceObservation.yaw` bridges as `NSNumber` here.
    private static func headYaw(_ face: VNFaceObservation) -> Double {
        (face.yaw as NSNumber?)?.doubleValue ?? 0
    }

    /// Landmark points; `normalizedPoints` is a C array, so reads go through `pointCount`.
    private static func points(of region: VNFaceLandmarkRegion2D) -> [CGPoint] {
        (0..<region.pointCount).map { region.normalizedPoints[$0] }
    }

    /// Eye height/width ratio; a closed eye collapses toward zero, unlike one point.
    private static func eyeAperture(_ landmarks: VNFaceLandmarks?) -> CGFloat? {
        // Per-region properties need the VNFaceLandmarks2D downcast.
        guard let region = (landmarks as? VNFaceLandmarks2D)?.leftEye
                ?? (landmarks as? VNFaceLandmarks2D)?.rightEye else { return nil }
        let points = points(of: region)
        guard points.count > 1 else { return nil }

        let ys = points.map(\.y)
        let xs = points.map(\.x)
        guard let top = ys.min(), let bottom = ys.max(),
              let minX = xs.min(), let maxX = xs.max() else { return nil }
        let width = maxX - minX
        guard width > 0 else { return nil }
        return abs(bottom - top) / width
    }

    /// Geometric smile proxy: Vision exposes no smile score, so threshold is high.
    private static func smileScore(_ landmarks: VNFaceLandmarks?) -> CGFloat {
        guard let lm = landmarks as? VNFaceLandmarks2D,
              let mouth = lm.outerLips,
              let inner = lm.innerLips else { return 0 }
        let outer = points(of: mouth)
        let innerPoints = points(of: inner)
        guard outer.count > 1, !innerPoints.isEmpty else { return 0 }

        let spread = abs(outer[0].x - outer[outer.count - 1].x)
        guard spread > 0 else { return 0 }
        let cornersY = (outer[0].y + outer[outer.count - 1].y) / 2
        let meanInnerY = innerPoints.reduce(0.0) { $0 + $1.y } / CGFloat(innerPoints.count)
        return min(1, max(0, (cornersY - meanInnerY) / spread * 6))
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension WakeChallengeViewController: AVCaptureMetadataOutputObjectsDelegate {

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard mode == .qr, !alarm.qrValue.isEmpty, !challengeComplete else { return }
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue,
                  value.trimmingCharacters(in: .whitespaces) == alarm.qrValue.trimmingCharacters(in: .whitespaces)
            else { continue }
            complete(method: "qr")
            return
        }
        setStatus(NSLocalizedString("challenge.wrong_code", comment: ""))
    }
}

enum WakeAction: CaseIterable {
    case blinkTwice, smile, turnLeft, turnRight, holdEyesOpen

    var hint: String {
        switch self {
        case .blinkTwice:
            return NSLocalizedString("action.blink.hint", comment: "")
        case .smile:
            return NSLocalizedString("action.smile.hint", comment: "")
        case .turnLeft:
            return NSLocalizedString("action.turn_left.hint", comment: "")
        case .turnRight:
            return NSLocalizedString("action.turn_right.hint", comment: "")
        case .holdEyesOpen:
            return NSLocalizedString("action.hold_open.hint", comment: "")
        }
    }

    var instruction: String {
        switch self {
        case .blinkTwice:
            return NSLocalizedString("action.blink", comment: "")
        case .smile:
            return NSLocalizedString("action.smile", comment: "")
        case .turnLeft:
            return NSLocalizedString("action.turn_left", comment: "")
        case .turnRight:
            return NSLocalizedString("action.turn_right", comment: "")
        case .holdEyesOpen:
            return NSLocalizedString("action.hold_open", comment: "")
        }
    }
}
