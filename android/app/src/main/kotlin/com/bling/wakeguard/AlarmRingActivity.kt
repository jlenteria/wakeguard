package com.bling.wakeguard

import android.animation.ObjectAnimator
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Native challenges: camera inference and dismissal never depend on Flutter. */
class AlarmRingActivity : AppCompatActivity() {
    private enum class Mode(val key: String, val title: String) {
        TAP("tap", "Tap"), FACE("face", "Face"), OBJECT("object", "Find an object"), QR("qr", "QR code")
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val analyzing = AtomicBoolean(false)
    private val objectProgress = ObjectRecognitionProgress()
    private val modeButtons = mutableMapOf<Mode, Button>()
    private var progressAnimator: ObjectAnimator? = null
    private lateinit var screen: FrameLayout
    private lateinit var instructionCard: LinearLayout
    private lateinit var instruction: TextView
    private lateinit var step: TextView
    private lateinit var hint: TextView
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    private lateinit var previewContainer: FrameLayout
    private lateinit var preview: PreviewView
    private lateinit var guide: ChallengeGuideView
    private lateinit var previewBadge: TextView
    private lateinit var retryCamera: Button
    private var provider: ProcessCameraProvider? = null
    private var faceDetector: com.google.mlkit.vision.face.FaceDetector? = null
    private var barcodeScanner: com.google.mlkit.vision.barcode.BarcodeScanner? = null
    private var objectLabeler: com.google.mlkit.vision.label.ImageLabeler? = null
    @Volatile private var generation = 0
    @Volatile private var destroyed = false
    @Volatile private var challengeComplete = false
    @Volatile private var mode = Mode.FACE
    private var cameraStarting = false
    private var cameraBoundGeneration = -1
    private var cameraPermissionRequested = false
    private var cameraUnavailable = false
    private var practice = false
    private var alarmId = ""
    private var sessionId: String? = null
    private var qrValue = ""
    private var objectTarget = "sink"
    private var escapes = setOf(AlarmDefaults.ESCAPE_FACE)
    private var actions = listOf<WakeAction>()
    private var actionIndex = 0
    private var blinkCount = 0
    private var eyesWereClosed = false
    private var eyesOpenSince = 0L
    private var lastFaceAt = 0L
    private var lastAnalysisAt = 0L
    private var lastObjectSecond = -1

    private val stopListener: () -> Unit = {
        runOnUiThread {
            if (!practice && !challengeComplete && RingingState.sessionId == sessionId) finishAndRemoveTask()
        }
    }

    private companion object {
        const val REQUEST_CAMERA = 4321
        const val ANALYSIS_MS = 180L
        const val SUCCESS_CLOSE_DELAY_MS = 5000L
        val BACKGROUND = Color.parseColor("#101114")
        val SURFACE = Color.parseColor("#202126")
        val ACCENT = Color.parseColor("#FF9B70")
        val MUTED = Color.parseColor("#B9BBC4")
        val SUCCESS = Color.parseColor("#8FE0B3")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        practice = intent.getBooleanExtra("practice", false)
        alarmId = intent.getStringExtra(NativeAlarmScheduler.EXTRA_ALARM_ID).orEmpty()
        sessionId = intent.getStringExtra(AlarmSessions.EXTRA_SESSION)
        val current = if (practice) null else AlarmSessions.get(this, alarmId)
        if (!practice && (current == null || current.token != sessionId || current.phase != "ringing")) {
            finishAndRemoveTask()
            return
        }
        if (current != null && current.alarm.needsSetup) {
            AlarmEvents.record(this, current, "challenge_setup_required")
            AlarmSessions.finish(this, current)
            Toast.makeText(this, "Open WakeGuard to set up this alarm's new challenge.", Toast.LENGTH_LONG).show()
            startActivity(Intent(this, MainActivity::class.java))
            finishAndRemoveTask()
            return
        }
        // The persisted occurrence wins over potentially stale PendingIntent extras.
        escapes = current?.alarm?.escapes ?: AlarmDefaults.escapesFromExtra(intent.getStringExtra(NativeAlarmScheduler.EXTRA_ESCAPES))
        qrValue = current?.alarm?.qrValue ?: intent.getStringExtra(NativeAlarmScheduler.EXTRA_QR).orEmpty()
        objectTarget = current?.alarm?.objectTarget ?: intent.getStringExtra(NativeAlarmScheduler.EXTRA_OBJECT_TARGET).orEmpty()
        if (objectTarget !in ObjectTargets.names) objectTarget = "sink"
        val steps = current?.alarm?.stepCount ?: intent.getIntExtra(NativeAlarmScheduler.EXTRA_STEPS, 2)
        actions = WakeAction.entries.shuffled().take(steps.coerceIn(1, 3)).let { picked ->
            if (picked.all { it == WakeAction.holdEyesOpen }) listOf(WakeAction.turnLeft) else picked
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        @Suppress("DEPRECATION")
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { if (practice) finishAndRemoveTask() }
        })
        mode = when {
            "face" in escapes -> Mode.FACE
            "object" in escapes -> Mode.OBJECT
            "qr" in escapes -> Mode.QR
            else -> Mode.TAP
        }
        screen = buildScreen(current?.alarm?.label ?: intent.getStringExtra(NativeAlarmScheduler.EXTRA_LABEL) ?: "Wake up")
        setContentView(screen)
        if (!practice) RingingState.onStopped = stopListener
        setMode(mode, animate = false)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); recreate() }

    private fun buildScreen(label: String): FrameLayout {
        val frame = FrameLayout(this).apply { setBackgroundColor(BACKGROUND) }
        val scroll = ScrollView(this).apply { isFillViewport = true }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(24), dp(20), dp(28))
        }
        scroll.addView(column, ViewGroup.LayoutParams(-1, -2))
        frame.addView(scroll, ViewGroup.LayoutParams(-1, -1))
        column.addView(text(if (practice) "PRACTICE · NO ALARM SCHEDULED" else "WAKEGUARD · A FRESH START", 12f, ACCENT))
        column.addView(text(label, 24f, Color.WHITE).apply { typeface = Typeface.DEFAULT_BOLD }, fullWidth(10))
        instructionCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(22), dp(22), dp(22))
            background = rounded(SURFACE)
        }
        instruction = text("", 28f, Color.WHITE).apply { typeface = Typeface.DEFAULT_BOLD }
        step = text("", 14f, MUTED)
        hint = text("", 14f, MUTED)
        status = text("", 14f, ACCENT).apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progressTintList = ColorStateList.valueOf(ACCENT)
            progressBackgroundTintList = ColorStateList.valueOf(Color.parseColor("#394046"))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        instructionCard.addView(instruction)
        instructionCard.addView(step, fullWidth(8))
        instructionCard.addView(progress, LinearLayout.LayoutParams(-1, dp(6)).apply { topMargin = dp(16) })
        instructionCard.addView(hint, fullWidth(14))
        instructionCard.addView(status, fullWidth(10))
        column.addView(instructionCard, fullWidth(22))
        preview = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        previewContainer = FrameLayout(this).apply { background = rounded(Color.BLACK, 24); clipToOutline = true }
        previewContainer.addView(preview, FrameLayout.LayoutParams(-1, -1))
        guide = ChallengeGuideView(this)
        previewContainer.addView(guide, FrameLayout.LayoutParams(-1, -1))
        previewBadge = text("", 12f, Color.WHITE).apply {
            background = rounded(Color.parseColor("#CC101114"), 12)
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        previewContainer.addView(previewBadge, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(14) })
        val previewHeight = (resources.displayMetrics.widthPixels * 0.85f).toInt().coerceAtMost(dp(360))
        column.addView(previewContainer, LinearLayout.LayoutParams(-1, previewHeight).apply { topMargin = dp(18) })
        retryCamera = button("Retry camera") {
            cameraPermissionRequested = false
            openCamera(requestPermission = true)
        }
        column.addView(retryCamera, fullWidth(12))
        if ("tap" in escapes) {
            column.addView(button(if (practice) "Finish practice" else "Stop alarm") { completeAlarm("tap") }.apply {
                background = rounded(ACCENT); setTextColor(BACKGROUND)
            }, fullWidth(16))
        }
        val modes = Mode.entries.filter { it.key in escapes && (it != Mode.QR || qrValue.isNotBlank()) }
        if (modes.size > 1) {
            column.addView(text("YOUR SELECTED CHALLENGES", 12f, MUTED), fullWidth(22))
            val row = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            modes.filter { it != Mode.TAP }.forEach { target ->
                val control = button(target.title) { setMode(target) }
                modeButtons[target] = control
                row.addView(control, fullWidth(8))
            }
            column.addView(row, fullWidth(0))
        }
        column.addView(text("Camera challenges need a well-lit room. Turn on the room light; screen brightness stays unchanged.", 12f, MUTED), fullWidth(18))
        if (practice) column.addView(button("Exit practice") { finishAndRemoveTask() }, fullWidth(14))
        return frame
    }

    private fun setMode(next: Mode, animate: Boolean = true) {
        if (challengeComplete || next.key !in escapes) return
        generation++
        mode = next
        objectProgress.reset()
        lastObjectSecond = -1
        actionIndex = 0
        blinkCount = 0
        eyesWereClosed = false
        eyesOpenSince = 0L
        setStatus("")
        guide.faceMode = next == Mode.FACE
        guide.detected = false
        guide.scanning = next != Mode.TAP
        // PreviewView mirrors the front camera automatically. An extra horizontal
        // flip would undo the mirror; recognition uses the original camera frames.
        preview.scaleX = 1f
        previewBadge.text = when (next) { Mode.FACE -> "FRONT CAMERA · MIRROR VIEW"; Mode.OBJECT -> "REAR CAMERA · ${ObjectTargets.title(objectTarget).uppercase()}"; else -> "REAR CAMERA · QR SCAN" }
        modeButtons.forEach { (target, control) ->
            val selected = target == next
            control.isSelected = selected
            control.background = rounded(if (selected) ACCENT else SURFACE, 14)
            control.setTextColor(if (selected) BACKGROUND else Color.WHITE)
        }
        if (animate && ChallengeGuideView.motionAllowed(this)) {
            instructionCard.animate().cancel()
            instructionCard.alpha = 0.5f
            instructionCard.translationY = dp(8).toFloat()
            instructionCard.animate().alpha(1f).translationY(0f).setDuration(180L).start()
        }
        updateInstructions()
        if (next == Mode.TAP) {
            provider?.unbindAll()
            cameraBoundGeneration = -1
        } else openCamera(requestPermission = true)
    }

    private fun updateInstructions() {
        previewContainer.visibility = if (mode != Mode.TAP && !cameraUnavailable) View.VISIBLE else View.GONE
        retryCamera.visibility = if (mode != Mode.TAP && cameraUnavailable) View.VISIBLE else View.GONE
        if (cameraUnavailable && mode != Mode.TAP) {
            guide.scanning = false
            instruction.text = "Camera unavailable"
            step.text = "Enable Camera in app settings, or close another app using it."
            hint.text = "Retry the camera or choose another challenge already selected for this alarm."
            setProgress(0f)
            return
        }
        when (mode) {
            Mode.TAP -> { instruction.text = "Good morning"; step.text = "Tap to stop is enabled for this alarm."; hint.text = "Choose Object or QR next time if you want a reason to leave bed."; setProgress(0f) }
            Mode.FACE -> {
                instruction.text = actions.getOrNull(actionIndex)?.instruction ?: "Face check"
                step.text = "Step ${actionIndex + 1} of ${actions.size}"
                hint.text = actions.getOrNull(actionIndex)?.hint ?: "Hold the phone at eye level. The preview works like a mirror."
                setProgress(actionIndex.toFloat() / actions.size.coerceAtLeast(1))
            }
            Mode.OBJECT -> {
                instruction.text = "Find your ${ObjectTargets.title(objectTarget)}"
                step.text = "Keep it clearly visible for 3 seconds"
                hint.text = if (objectTarget == "sink") "Show the whole sink basin and faucet in good light. Hold the phone steady; brief detection pauses will not erase your progress."
                    else "Point the rear camera at your cup in good light. Keep it in view until the progress bar fills."
                setProgress(0f)
            }
            Mode.QR -> { instruction.text = "Scan your wake-up QR"; step.text = "Use the code saved for this alarm"; hint.text = "Point the rear camera at the whole code. Hold steady in good light; scanning is automatic."; setProgress(0f) }
        }
    }

    private fun hasCameraPermission() = ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun openCamera(requestPermission: Boolean = false) {
        if (destroyed || challengeComplete || mode == Mode.TAP) return
        // onCreate/onStart can run before the lifecycle registry reaches STARTED.
        // onResume posts a retry after the framework has completed that transition.
        if (!lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) return
        if (!hasCameraPermission()) {
            cameraUnavailable = true
            updateInstructions()
            if (requestPermission && !cameraPermissionRequested) {
                cameraPermissionRequested = true
                requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQUEST_CAMERA)
            }
            return
        }
        if (cameraStarting || (cameraBoundGeneration == generation && !cameraUnavailable)) return
        // Make the preview visible before binding so its surface can be created.
        cameraUnavailable = false
        guide.scanning = true
        updateInstructions()
        cameraStarting = true
        val expected = generation
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            cameraStarting = false
            if (destroyed || challengeComplete || !lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) return@addListener
            if (expected != generation) { openCamera(); return@addListener }
            runCatching { bindCamera(future.get()) }.onFailure { cameraError("Could not open the camera. Close other camera apps and retry.", it) }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun bindCamera(cameraProvider: ProcessCameraProvider) {
        if (mode == Mode.TAP || destroyed || challengeComplete) return
        if (mode == Mode.FACE && faceDetector == null) faceDetector = FaceDetection.getClient(
            FaceDetectorOptions.Builder().setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL).build())
        if (mode == Mode.QR && barcodeScanner == null) barcodeScanner = BarcodeScanning.getClient()
        if (mode == Mode.OBJECT && objectLabeler == null) objectLabeler = ImageLabeling.getClient(
            ImageLabelerOptions.Builder().setConfidenceThreshold(ObjectTargets.MODEL_CONFIDENCE).build())
        provider = cameraProvider
        cameraProvider.unbindAll()
        val cameraPreview = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
        val analysis = ImageAnalysis.Builder().setTargetResolution(android.util.Size(640, 480))
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        analysis.setAnalyzer(executor, ::analyze)
        val selector = if (mode == Mode.FACE) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        cameraProvider.bindToLifecycle(this, selector, cameraPreview, analysis)
        cameraBoundGeneration = generation
        cameraUnavailable = false
        guide.scanning = true
        updateInstructions()
    }

    private fun cameraError(message: String, error: Throwable? = null) {
        generation++
        cameraBoundGeneration = -1
        runCatching { provider?.unbindAll() }
        cameraUnavailable = true
        objectProgress.reset()
        updateInstructions()
        setStatus(message)
        if (error != null) android.util.Log.w("WakeGuard", message, error)
    }

    private fun analyze(proxy: ImageProxy) {
        val now = SystemClock.elapsedRealtime()
        if (destroyed || challengeComplete || mode == Mode.TAP || now - lastAnalysisAt < ANALYSIS_MS || !analyzing.compareAndSet(false, true)) {
            proxy.close(); return
        }
        lastAnalysisAt = now
        val media = proxy.image
        if (media == null) { proxy.close(); analyzing.set(false); return }
        val expected = generation
        val selected = mode
        fun active() = !destroyed && !challengeComplete && generation == expected && mode == selected &&
            lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
        try {
            val image = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
            when (selected) {
                Mode.FACE -> {
                    val detector = faceDetector ?: run { proxy.close(); analyzing.set(false); return }
                    detector.process(image).addOnSuccessListener { faces ->
                        if (!active()) return@addOnSuccessListener
                        if (faces.size != 1) {
                            eyesOpenSince = 0L; eyesWereClosed = false; guide.detected = false
                            setStatus(if (faces.isEmpty()) "Turn on the room light and bring your face into view." else "Keep only your face in view.")
                        } else { guide.detected = true; evaluateFace(faces.first()) }
                    }.addOnFailureListener { if (active()) cameraError("Face recognition failed. Retry the camera.", it) }
                        .addOnCompleteListener { proxy.close(); analyzing.set(false) }
                }
                Mode.QR -> {
                    val scanner = barcodeScanner ?: run { proxy.close(); analyzing.set(false); return }
                    scanner.process(image).addOnSuccessListener { codes ->
                        if (!active()) return@addOnSuccessListener
                        val matched = qrValue.isNotBlank() && codes.any { it.rawValue?.trim() == qrValue.trim() }
                        guide.detected = matched
                        if (matched) completeAlarm("qr") else if (codes.isNotEmpty()) setStatus("That is a different code. Find your wake-up QR.")
                    }.addOnFailureListener { if (active()) cameraError("QR recognition failed. Retry the camera.", it) }
                        .addOnCompleteListener { proxy.close(); analyzing.set(false) }
                }
                Mode.OBJECT -> {
                    val labeler = objectLabeler ?: run { proxy.close(); analyzing.set(false); return }
                    labeler.process(image).addOnSuccessListener { labels ->
                        if (!active()) return@addOnSuccessListener
                        val now = SystemClock.elapsedRealtime()
                        val matched = ObjectTargets.matches(objectTarget, labels, maintaining = objectProgress.isTracking(now))
                        val amount = objectProgress.update(matched, now, tolerateBriefMisses = objectTarget == "sink")
                        guide.detected = matched || amount > 0f
                        setProgress(amount)
                        val remaining = kotlin.math.ceil((1f - amount) * 3f).toInt()
                        if (!matched) {
                            lastObjectSecond = -1
                            setStatus(if (amount > 0f) "Hold steady · bring the sink back into view"
                                else if (objectTarget == "sink") "Show the whole sink basin and faucet. Try a different angle or brighter light."
                                else "Looking for your cup. Move closer and turn on the room light.")
                        } else if (lastObjectSecond != remaining) {
                            lastObjectSecond = remaining
                            setStatus("Object found · keep it in view · ${remaining.coerceAtLeast(1)} seconds")
                        }
                        if (amount >= 1f) completeAlarm("object")
                    }.addOnFailureListener {
                        if (active()) { objectProgress.reset(); cameraError("Object recognition failed. Retry the camera.", it) }
                    }.addOnCompleteListener { proxy.close(); analyzing.set(false) }
                }
                Mode.TAP -> { proxy.close(); analyzing.set(false) }
            }
        } catch (error: Exception) {
            proxy.close(); analyzing.set(false)
            runOnUiThread { if (active()) cameraError("Camera recognition failed. Retry the camera.", error) }
        }
    }

    private fun evaluateFace(face: Face) {
        if (challengeComplete || mode != Mode.FACE) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastFaceAt > 700L) { eyesOpenSince = 0L; eyesWereClosed = false }
        lastFaceAt = now
        val action = actions.getOrNull(actionIndex) ?: return
        val left = face.leftEyeOpenProbability
        val right = face.rightEyeOpenProbability
        if ((action == WakeAction.blinkTwice || action == WakeAction.holdEyesOpen) && (left == null || right == null)) {
            eyesOpenSince = 0L; eyesWereClosed = false
            setStatus("Look straight at the camera so both eyes are visible."); return
        }
        val closed = (left ?: 1f) < 0.28f && (right ?: 1f) < 0.28f
        val open = (left ?: 0f) > 0.72f && (right ?: 0f) > 0.72f
        val passed = when (action) {
            WakeAction.blinkTwice -> {
                if (closed) eyesWereClosed = true
                if (eyesWereClosed && open) { blinkCount++; eyesWereClosed = false }
                setStatus(if (eyesWereClosed) "Reopen both eyes · $blinkCount of 2 blinks" else "$blinkCount of 2 blinks · close and reopen both eyes")
                blinkCount >= 2
            }
            WakeAction.smile -> { setStatus("Face found · Give a clear smile"); (face.smilingProbability ?: 0f) > 0.72f }
            WakeAction.turnLeft -> { setStatus("Face found · Turn your head left"); face.headEulerAngleY > 22f }
            WakeAction.turnRight -> { setStatus("Face found · Turn your head right"); face.headEulerAngleY < -22f }
            WakeAction.holdEyesOpen -> {
                if (open) {
                    if (eyesOpenSince == 0L) eyesOpenSince = now
                    val elapsed = now - eyesOpenSince
                    setProgress((actionIndex + (elapsed / 5000f).coerceAtMost(1f)) / actions.size.coerceAtLeast(1))
                    setStatus("Keep both eyes open · ${kotlin.math.ceil((5000L - elapsed).coerceAtLeast(0) / 1000.0).toInt()} seconds")
                    elapsed >= 5000L
                } else {
                    eyesOpenSince = 0L
                    setProgress(actionIndex.toFloat() / actions.size.coerceAtLeast(1))
                    setStatus("Open both eyes to start the 5-second check"); false
                }
            }
        }
        if (!passed) return
        actionIndex++
        blinkCount = 0; eyesWereClosed = false; eyesOpenSince = 0L
        instructionCard.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY)
        if (actionIndex >= actions.size) completeAlarm("face") else {
            setStatus("Step complete")
            if (ChallengeGuideView.motionAllowed(this)) {
                instructionCard.animate().scaleX(1.02f).scaleY(1.02f).setDuration(90).withEndAction {
                    instructionCard.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                }.start()
            }
            updateInstructions()
        }
    }

    private fun completeAlarm(method: String) {
        if (challengeComplete || method !in escapes) return
        val before = if (practice) null else AlarmSessions.get(this, alarmId)
        challengeComplete = true
        try {
            if (practice && method == "object") ObjectTargets.recordPractice(this, objectTarget)
            if (!practice && !AlarmDismissal.complete(this, alarmId, method, sessionId)) {
                finishAndRemoveTask(); return
            }
        } catch (failure: Exception) {
            challengeComplete = false
            setStatus("Could not finish the alarm. Please try again.")
            android.util.Log.e("WakeGuard", "Dismissal failed", failure)
            return
        }
        generation++
        provider?.unbindAll()
        guide.scanning = false
        guide.detected = true
        setProgress(1f)
        val after = if (practice) null else AlarmSessions.get(this, alarmId)
        val detail = when {
            practice && method == "object" -> "Object verified. Return to the editor to enable your alarm."
            practice -> "Practice complete. No alarm or check-in was scheduled."
            after?.phase == "checkin" -> "Stay Awake check-in in ${after.alarm.checkInMinutes} minutes."
            before != null && AlarmPolicy.needsCheckIn(before.alarm.checkInMinutes, before.followUp) ->
                "Alarm stopped, but the check-in could not be scheduled. Check History and Health."
            else -> "Alarm stopped. Have a good morning."
        }
        val quote = MotivationalQuotes.next(this)
        // Audio and camera stop first; confirmation never delays check-in scheduling.
        val success = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(BACKGROUND)
        }
        ViewCompat.setOnApplyWindowInsetsListener(success) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(32), dp(24), dp(32))
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(32), dp(24), dp(28))
            background = rounded(SURFACE, 28)
            addView(text(if (practice) "PRACTICE COMPLETE" else "WAKE CHECK COMPLETE", 12f, SUCCESS))
            addView(text("✓", 48f, SUCCESS).apply {
                background = rounded(Color.parseColor("#19382C"), 48)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(88), dp(88)).apply { topMargin = dp(24) })
            addView(text(if (practice) "You did it!" else "You're ready", 30f, Color.WHITE).apply {
                typeface = Typeface.DEFAULT_BOLD
                ViewCompat.setAccessibilityHeading(this, true)
            }, fullWidth(24))
            addView(text(detail, 16f, MUTED), fullWidth(12))
            if (quote != null) {
                addView(text("“$quote”", 18f, SUCCESS).apply {
                    setPadding(dp(18), dp(18), dp(18), dp(18))
                    background = rounded(Color.parseColor("#19382C"), 16)
                    setLineSpacing(dp(4).toFloat(), 1f)
                }, fullWidth(20))
            }
            addView(button(if (practice) "Back to editor" else "Close") { finishAndRemoveTask() }.apply {
                background = rounded(ACCENT, 16)
                setTextColor(BACKGROUND)
            }, fullWidth(28))
            addView(text("Closes automatically in 5 seconds", 12f, MUTED), fullWidth(14))
        }
        content.addView(card, fullWidth())
        success.addView(content, ViewGroup.LayoutParams(-1, -2))
        screen.removeAllViews()
        screen.addView(success, FrameLayout.LayoutParams(-1, -1))
        ViewCompat.requestApplyInsets(success)
        success.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY)
        if (ChallengeGuideView.motionAllowed(this)) {
            success.alpha = 0f; success.scaleX = 0.96f; success.scaleY = 0.96f
            success.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(220).start()
        }
        success.announceForAccessibility("${if (practice) "Practice complete" else "Alarm stopped"}. $detail")
        main.postDelayed({ if (!destroyed) finishAndRemoveTask() }, SUCCESS_CLOSE_DELAY_MS)
    }

    private fun setProgress(amount: Float) {
        val goal = (amount.coerceIn(0f, 1f) * 1000).toInt()
        progressAnimator?.cancel()
        if (ChallengeGuideView.motionAllowed(this)) {
            progressAnimator = ObjectAnimator.ofInt(progress, "progress", progress.progress, goal).apply { duration = 120; start() }
        } else progress.progress = goal
    }

    private fun setStatus(value: String) {
        if (status.text.toString() == value) return
        status.text = value
        status.visibility = if (value.isBlank()) View.GONE else View.VISIBLE
    }

    private fun button(title: String, action: () -> Unit) = Button(this).apply {
        text = title; isAllCaps = false; minimumHeight = dp(54)
        setTextColor(Color.WHITE); background = rounded(SURFACE, 14)
        setPadding(dp(16), dp(12), dp(16), dp(12))
        setOnClickListener { action() }
    }
    private fun text(value: String, size: Float, color: Int) = TextView(this).apply {
        text = value; setTextSize(TypedValue.COMPLEX_UNIT_SP, size); setTextColor(color); gravity = Gravity.CENTER
    }
    private fun rounded(color: Int, radius: Int = 22) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }
    private fun fullWidth(top: Int = 0) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onStart() {
        super.onStart()
        if (::guide.isInitialized && !challengeComplete) guide.scanning = mode != Mode.TAP
    }
    override fun onResume() {
        super.onResume()
        if (!::preview.isInitialized) return
        preview.post {
            if (!destroyed && !challengeComplete &&
                lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)) {
                openCamera(requestPermission = true)
            }
        }
    }
    override fun onStop() {
        generation++
        objectProgress.reset(); eyesOpenSince = 0L; eyesWereClosed = false
        if (::guide.isInitialized) guide.scanning = false
        progressAnimator?.cancel()
        if (::instructionCard.isInitialized) instructionCard.animate().cancel()
        runCatching { provider?.unbindAll() }
        cameraBoundGeneration = -1
        super.onStop()
    }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code != REQUEST_CAMERA || mode == Mode.TAP || challengeComplete) return
        if (results.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) openCamera()
        else cameraError("Camera permission is denied. Enable it in Android app settings.")
    }
    override fun onDestroy() {
        destroyed = true; generation++
        if (RingingState.onStopped === stopListener) RingingState.onStopped = null
        main.removeCallbacksAndMessages(null)
        progressAnimator?.cancel()
        runCatching { provider?.unbindAll() }
        runCatching { faceDetector?.close() }
        runCatching { barcodeScanner?.close() }
        runCatching { objectLabeler?.close() }
        executor.shutdown()
        super.onDestroy()
    }
}

enum class WakeAction(val instruction: String, val hint: String) {
    blinkTwice("Blink twice", "Look straight at the camera. Slowly close and reopen both eyes twice."),
    smile("Smile", "Look straight at the camera and give a clear smile. Keep your whole face in view."),
    turnLeft("Turn your head left", "The preview works like a mirror. Keep the phone still and turn toward your own left shoulder."),
    turnRight("Turn your head right", "The preview works like a mirror. Keep the phone still and turn toward your own right shoulder."),
    holdEyesOpen("Keep both eyes open for 5 seconds", "Look straight at the camera. Keep both eyes open until the countdown ends; closing them restarts it.")
}

object AlarmIntents {
    fun ringActivity(context: Context, alarm: StoredAlarm): Intent = Intent(context, AlarmRingActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        putExtra(NativeAlarmScheduler.EXTRA_ALARM_ID, alarm.id)
        putExtra(NativeAlarmScheduler.EXTRA_LABEL, alarm.label)
        putExtra(NativeAlarmScheduler.EXTRA_QR, alarm.qrValue)
        putExtra(NativeAlarmScheduler.EXTRA_STEPS, alarm.stepCount)
        putExtra(NativeAlarmScheduler.EXTRA_ESCAPES, NativeAlarmScheduler.escapesExtra(alarm))
        putExtra(NativeAlarmScheduler.EXTRA_OBJECT_TARGET, alarm.objectTarget)
        putExtra(AlarmSessions.EXTRA_SESSION, AlarmSessions.get(context, alarm.id)?.token)
        data = android.net.Uri.parse("wakeguard://ring/${alarm.id}/${AlarmSessions.get(context, alarm.id)?.token}")
    }
}
