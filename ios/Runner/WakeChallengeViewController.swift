import AVFoundation
import UIKit
import Vision

/// The native iOS wake challenge.
///
/// Presented natively rather than through Flutter, for the same reason as the
/// Android equivalent: dismissing a live alarm must not depend on the Flutter
/// engine or the Dart isolate being alive.
///
/// Face detection uses Vision rather than ML Kit. Vision is part of the OS, works
/// fully offline, loads no bundled model, and exposes head pose plus eye and
/// mouth landmarks. QR detection uses `AVCaptureMetadataOutput`, which is also
/// built in, so the whole challenge adds zero third-party dependencies.
///
/// Four escapes, any one of which completes the alarm: face actions, a typed
/// answer, a QR code away from bed, and a deliberate ten second hold. On iOS the
/// typed path matters more than on Android because the camera cannot run from
/// the lock screen at all.
final class WakeChallengeViewController: UIViewController {

    private enum Mode { case face, typed, qr }

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

    private let answerField = UITextField()
    private let instructionLabel = UILabel()
    private let statusLabel = UILabel()
    private let stepLabel = UILabel()

    private var lastAnalysis = Date.distantPast
    private var cameraUnavailable = false

    // Face action state machine.
    private var eyesWereClosed = false
    private var typedAnswer = 0
    private var blinkCount = 0
    private var holdStartedAt: Date?

    private static let analysisInterval: TimeInterval = 0.12

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
        view.backgroundColor = .black
        buildLayout()
        updateInstructions()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        instructionLabel.textColor = .white
        instructionLabel.font = .systemFont(ofSize: 30, weight: .bold)
        instructionLabel.numberOfLines = 0
        instructionLabel.textAlignment = .center

        stepLabel.textColor = .lightGray
        stepLabel.font = .systemFont(ofSize: 14)
        stepLabel.textAlignment = .center

        statusLabel.textColor = UIColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [
            instructionLabel,
            stepLabel,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let preview = UIView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.layer.cornerRadius = 20
        preview.clipsToBounds = true
        preview.backgroundColor = UIColor(white: 0.08, alpha: 1)
        preview.tag = 1001
        view.addSubview(preview)

        let modeRow = UIStackView()
        modeRow.axis = .horizontal
        modeRow.distribution = .fillEqually
        modeRow.spacing = 8
        modeRow.translatesAutoresizingMaskIntoConstraints = false
        modeRow.addArrangedSubview(modeButton("Face", .face))
        modeRow.addArrangedSubview(modeButton("Type", .typed))
        if !alarm.qrValue.isEmpty {
            modeRow.addArrangedSubview(modeButton("QR", .qr))
        }
        view.addSubview(modeRow)

        answerField.keyboardType = .numberPad
        answerField.textColor = .white
        answerField.textAlignment = .center
        answerField.font = .systemFont(ofSize: 26)
        answerField.backgroundColor = UIColor(white: 0.15, alpha: 1)
        answerField.layer.cornerRadius = 10
        answerField.isHidden = true
        answerField.translatesAutoresizingMaskIntoConstraints = false
        answerField.accessibilityLabel = NSLocalizedString("challenge.answer.label", comment: "")
        view.addSubview(answerField)

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle(NSLocalizedString("challenge.confirm", comment: ""), for: .normal)
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1)
        confirmButton.layer.cornerRadius = 12
        confirmButton.isHidden = true
        confirmButton.addTarget(self, action: #selector(confirmTypedAnswer), for: .touchUpInside)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(confirmButton)

        let holdButton = HoldToStopButton(
            title: NSLocalizedString("challenge.hold", comment: ""),
            duration: 10,
            tint: UIColor(red: 0.72, green: 0.11, blue: 0.11, alpha: 1)
        )
        holdButton.onComplete = { [weak self] in self?.complete(method: "hold") }
        holdButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(holdButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            preview.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.75),

            modeRow.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 16),
            modeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            modeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            answerField.topAnchor.constraint(equalTo: modeRow.bottomAnchor, constant: 12),
            answerField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            answerField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            answerField.heightAnchor.constraint(equalToConstant: 52),

            confirmButton.topAnchor.constraint(equalTo: answerField.bottomAnchor, constant: 8),
            confirmButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            confirmButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            confirmButton.heightAnchor.constraint(equalToConstant: 48),

            holdButton.topAnchor.constraint(equalTo: confirmButton.bottomAnchor, constant: 16),
            holdButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            holdButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            holdButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -16
            ),
            holdButton.heightAnchor.constraint(equalToConstant: 76),
        ])

        // The locked phone must not sleep while a challenge is on screen.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func modeButton(_ title: String, _ target: Mode) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 0.2, alpha: 1)
        button.layer.cornerRadius = 10
        button.addAction(
            UIAction { [weak self] _ in self?.setMode(target) },
            for: .touchUpInside
        )
        return button
    }

    // MARK: - Mode

    private func setMode(_ next: Mode) {
        let cameraChangesLens = (next == .qr) != (mode == .qr)
        mode = next
        let typing = next == .typed
        answerField.isHidden = !typing
        view.viewWithTag(1001)?.isHidden = typing
        if typing {
            rollTypedChallenge()
        }
        if cameraChangesLens {
            refitCameraInput(position(for: next))
        }
        setStatus("")
        updateInstructions()
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
        DispatchQueue.main.async { self.statusLabel.text = text }
    }

    // MARK: - Capture

    /// The front camera reads faces; the rear camera reads QR codes printed on
    /// cards. A QR code is meant to be pointed at a phone, so scanning it with
    /// the selfie camera would make the challenge impossible.
    private func position(for selectedMode: Mode) -> AVCaptureDevice.Position {
        selectedMode == .qr ? .back : .front
    }

    /// Swaps the session to the lens [position(for:)] asks for, dropping the
    /// previous input so the two cameras cannot stack up in one session.
    private func refitCameraInput(_ wanted: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: wanted
            ),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
    }

    private func startSession() {
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
        cameraUnavailable = true
        DispatchQueue.main.async {
            self.setStatus(NSLocalizedString("challenge.camera_denied", comment: ""))
            self.updateInstructions()
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
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

            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.metadataObjectTypes = [.qr]
            }

            session.commitConfiguration()
            session.startRunning()

            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                if let container = self.view.viewWithTag(1001) {
                    layer.frame = container.bounds
                    container.layer.insertSublayer(layer, at: 0)
                }
                self.previewLayer = layer
            }
        }
    }

    // MARK: - Completion

    private func complete(method: String) {
        guard !challengeComplete else { return }
        challengeComplete = true
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        AlarmActionHandler.shared.dismissFromChallenge(alarmId: alarm.id, method: method)
        dismiss(animated: true)
    }

    /// Random action subset, guaranteeing at least one action that needs real
    /// head or eye movement so the challenge cannot be passed from bed.
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

        let request = VNDetectFaceLandmarksRequest { [weak self] request, _ in
            guard let self else { return }
            guard let observation = (request.results as? [VNFaceObservation])?.first else {
                setStatus(NSLocalizedString("challenge.no_face", comment: ""))
                return
            }
            evaluate(observation)
        }
        request.revision = VNDetectFaceLandmarksRequestRevision3

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
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
            let aperture = Self.eyeAperture(landmarks)
            if aperture < 0.28 { eyesWereClosed = true }
            if eyesWereClosed && aperture > 0.62 {
                blinkCount += 1
                eyesWereClosed = false
                passed = blinkCount >= 2
            }

        case .smile:
            passed = Self.smileScore(landmarks) > 0.6

        case .turnLeft:
            passed = Self.headYaw(face) < -0.38
        case .turnRight:
            passed = Self.headYaw(face) > 0.38

        case .holdEyesOpen:
            if Self.eyeAperture(landmarks) > 0.55 {
                if holdStartedAt == nil { holdStartedAt = Date() }
                let held = Date().timeIntervalSince(holdStartedAt!)
                setStatus(String(
                    format: NSLocalizedString("challenge.keep_open", comment: ""),
                    max(0, 5 - Int(held))
                ))
                passed = held >= 5
            } else {
                holdStartedAt = nil
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

    /// Head yaw in radians. `VNFaceObservation.yaw` is bridged as an `NSNumber`
    /// in this SDK, so it needs an explicit numeric conversion.
    private static func headYaw(_ face: VNFaceObservation) -> Double {
        (face.yaw as NSNumber?)?.doubleValue ?? 0
    }

    /// Points of a landmark region.
    ///
    /// `normalizedPoints` is a C array behind an inner pointer, so it cannot be
    /// indexed as a Swift collection; each read has to go through `pointCount`.
    private static func points(of region: VNFaceLandmarkRegion2D) -> [CGPoint] {
        (0..<region.pointCount).map { region.normalizedPoints[$0] }
    }

    /// Ratio of eye height to eye width. A closed eye collapses toward zero,
    /// which is far more reliable than tracking any single landmark point.
    private static func eyeAperture(_ landmarks: VNFaceLandmarks?) -> CGFloat {
        // The per-region properties live on VNFaceLandmarks2D; the observation
        // only vends the base class, so the downcast is required.
        guard let region = (landmarks as? VNFaceLandmarks2D)?.leftEye
                ?? (landmarks as? VNFaceLandmarks2D)?.rightEye else { return 1 }
        let points = points(of: region)
        guard points.count > 1 else { return 1 }

        let ys = points.map(\.y)
        let xs = points.map(\.x)
        guard let top = ys.min(), let bottom = ys.max(),
              let minX = xs.min(), let maxX = xs.max() else { return 1 }
        let width = maxX - minX
        guard width > 0 else { return 1 }
        return abs(bottom - top) / width
    }

    /// Cheap smile proxy: how far the mouth corners sit above the inner lips,
    /// scaled by mouth width. Vision exposes no smile probability, so this is a
    /// geometric approximation and deliberately has a high threshold.
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
