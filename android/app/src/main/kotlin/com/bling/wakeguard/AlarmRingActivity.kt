package com.bling.wakeguard

import android.animation.ObjectAnimator
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.os.CountDownTimer
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
import android.widget.ImageView
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
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.AccessibilityDelegateCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.core.widget.TextViewCompat
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
    private class ModeRow(val root: LinearLayout, val icon: ImageView, val title: TextView, val badge: TextView, val chevron: ImageView)
    private val modeButtons = mutableMapOf<Mode, ModeRow>()
    private var progressAnimator: ObjectAnimator? = null
    private lateinit var screen: FrameLayout
    private lateinit var instructionCard: LinearLayout
    private lateinit var instruction: TextView
    private lateinit var step: TextView
    private lateinit var stepDots: LinearLayout
    private lateinit var instructionIcon: ImageView
    private lateinit var hint: TextView
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    private lateinit var previewContainer: FrameLayout
    private lateinit var preview: PreviewView
    private lateinit var guide: ChallengeGuideView
    private lateinit var previewBadge: TextView
    private var activeCount: TextView? = null
    private val headlineFont by lazy { loadFont(R.font.plus_jakarta_sans_bold, Typeface.DEFAULT_BOLD) }
    private val labelFont by lazy { loadFont(R.font.inter_semibold, Typeface.DEFAULT_BOLD) }
    private val bodyFont by lazy { loadFont(R.font.inter_regular, Typeface.DEFAULT) }
    private lateinit var retryCamera: Button
    private var provider: ProcessCameraProvider? = null
    @Volatile private var faceDetector: com.google.mlkit.vision.face.FaceDetector? = null
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
    @Volatile private var qrValue = ""
    @Volatile private var objectTarget = "sink"
    private var escapes = setOf(AlarmDefaults.ESCAPE_FACE)
    @Volatile private var actions = listOf<WakeAction>()
    private var actionIndex = 0
    private var blinkCount = 0
    private var eyesWereClosed = false
    private var eyesOpenSince = 0L
    private var lastFaceAt = 0L
    private var lastAnalysisAt = 0L
    private var lastObjectSecond = -1
    private var successCountdown: CountDownTimer? = null

    private val stopListener: () -> Unit = {
        runOnUiThread {
            if (!practice && !challengeComplete && RingingState.sessionId == sessionId) finishAndRemoveTask()
        }
    }

    private companion object {
        const val REQUEST_CAMERA = 4321
        const val ANALYSIS_MS = 180L
        const val SUCCESS_CLOSE_DELAY_MS = 5000L
        // Obsidian Dawn palette.
        val BACKGROUND = Color.parseColor("#10141A")
        val SURFACE = Color.parseColor("#1C2026")
        val ELEVATED = Color.parseColor("#262A31")
        val HIGHEST = Color.parseColor("#31353C")
        val LOWEST = Color.parseColor("#0A0E14")
        val BORDER = Color.parseColor("#14FFFFFF")
        val TEXT = Color.parseColor("#DFE2EB")
        val SECONDARY = Color.parseColor("#DAC1B9")
        val MUTED = Color.parseColor("#8B949E")
        val ACCENT = Color.parseColor("#FF9E79")
        val ON_ACCENT = Color.parseColor("#783316")
        val PEACH = Color.parseColor("#FFC5B1")
        val CYAN = Color.parseColor("#00F1FD")
        val CYAN_DIM = Color.parseColor("#00DCE6")
        val AMBER = Color.parseColor("#FF9F66")
        val SUCCESS = CYAN
        const val PILL = 100
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
        val scroll = ScrollView(this).apply { isFillViewport = true; clipToPadding = false }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            clipChildren = false
            clipToPadding = false
            setPadding(dp(20), dp(8), dp(20), dp(32))
        }
        scroll.addView(column, ViewGroup.LayoutParams(-1, -2))
        frame.addView(scroll, ViewGroup.LayoutParams(-1, -1))
        column.addView(labelText(if (practice) "PRACTICE • NO ALARM SCHEDULED" else "WAKEGUARD • A FRESH START", PEACH, 0.05f).apply {
            background = rounded(Color.parseColor("#99262A31"), PILL)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            setCompoundDrawablesRelative(dot(PEACH, 6), null, null, null)
            compoundDrawablePadding = dp(6)
        }, LinearLayout.LayoutParams(-2, -2))
        if (!practice) column.addView(text(label, 14f, SECONDARY).apply { setLeading(20f) }, fullWidth(8))
        instruction = text("", 26f, TEXT).apply {
            typeface = headlineFont
            letterSpacing = -0.025f
            setLeading(32f)
            ViewCompat.setAccessibilityHeading(this, true)
        }
        column.addView(instruction, fullWidth(8))
        step = text("", 13f, SECONDARY).apply { typeface = labelFont; letterSpacing = 0.02f; setLeading(18f) }
        stepDots = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        val stepRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(step, LinearLayout.LayoutParams(-2, -2))
            addView(stepDots, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(8) })
        }
        column.addView(stepRow, fullWidth(4))
        instructionCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(dp(16), dp(16), dp(16), dp(16))
            // Card fill plus the soft primary glow in its top-right corner.
            background = LayerDrawable(arrayOf(rounded(SURFACE, 32), GradientDrawable().apply {
                gradientType = GradientDrawable.RADIAL_GRADIENT
                colors = intArrayOf(Color.parseColor("#1FFFC5B1"), Color.TRANSPARENT)
                gradientRadius = dp(96).toFloat()
                setGradientCenter(0.96f, 0.06f)
                cornerRadius = dp(32).toFloat()
            }))
            elevation = dp(4).toFloat()
        }
        instructionIcon = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = rounded(ELEVATED, PILL)
            imageTintList = ColorStateList.valueOf(PEACH)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        instructionCard.addView(instructionIcon, LinearLayout.LayoutParams(dp(40), dp(40)))
        val cardBody = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        instructionCard.addView(cardBody, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(12) })
        hint = text("", 14f, TEXT).apply { gravity = Gravity.START; setLeading(19.25f) }
        status = labelText("", PEACH, 0.04f).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            setCompoundDrawablesRelative(glyph(R.drawable.wg_ic_sun, PEACH, 16), null, null, null)
            compoundDrawablePadding = dp(6)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progressDrawable = LayerDrawable(arrayOf(
                rounded(HIGHEST, PILL),
                ClipDrawable(rounded(ACCENT, PILL), Gravity.START, ClipDrawable.HORIZONTAL),
            )).apply {
                setId(0, android.R.id.background)
                setId(1, android.R.id.progress)
            }
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        cardBody.addView(hint, fullWidth())
        cardBody.addView(status, fullWidth(10))
        cardBody.addView(progress, LinearLayout.LayoutParams(-1, dp(6)).apply { topMargin = dp(12) })
        column.addView(instructionCard, fullWidth(16))
        preview = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        previewContainer = FrameLayout(this).apply {
            background = rounded(LOWEST, 32)
            clipToOutline = true
            elevation = dp(8).toFloat()
        }
        previewContainer.addView(preview, FrameLayout.LayoutParams(-1, -1))
        previewContainer.addView(View(this).apply {
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(
                Color.parseColor("#4D10141A"), Color.TRANSPARENT, Color.parseColor("#CC10141A")))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, FrameLayout.LayoutParams(-1, -1))
        guide = ChallengeGuideView(this)
        previewContainer.addView(guide, FrameLayout.LayoutParams(-1, -1))
        previewBadge = labelText("", TEXT, 0.05f).apply {
            background = rounded(Color.parseColor("#D90A0E14"), PILL)
            setPadding(dp(14), dp(6), dp(14), dp(6))
            setCompoundDrawablesRelative(dot(CYAN, 8), null, null, null)
            compoundDrawablePadding = dp(8)
            elevation = dp(6).toFloat()
        }
        previewContainer.addView(previewBadge, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(16) })
        // Square viewfinder spanning the content width, as in the design.
        val previewSize = (resources.displayMetrics.widthPixels - dp(40)).coerceIn(dp(200), dp(440))
        column.addView(previewContainer, LinearLayout.LayoutParams(-1, previewSize).apply { topMargin = dp(16) })
        retryCamera = button("Retry camera") {
            cameraPermissionRequested = false
            openCamera(requestPermission = true)
        }
        column.addView(retryCamera, LinearLayout.LayoutParams(-1, dp(56)).apply { topMargin = dp(16) })
        val modes = Mode.entries.filter { it.key in escapes && (it != Mode.QR || qrValue.isNotBlank()) }
        if (modes.size > 1) {
            val cameraModes = modes.filter { it != Mode.TAP }
            val count = labelText("", CYAN_DIM, 0.04f)
            activeCount = count
            val header = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(4), 0, dp(4), 0)
                addView(labelText("YOUR SELECTED CHALLENGES", SECONDARY, 0.05f).apply { gravity = Gravity.START }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(count, LinearLayout.LayoutParams(-2, -2))
            }
            column.addView(header, fullWidth(16))
            val row = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; clipChildren = false; clipToPadding = false }
            cameraModes.forEachIndexed { index, target ->
                val control = modeRow(target)
                modeButtons[target] = control
                row.addView(control.root, LinearLayout.LayoutParams(-1, dp(56)).apply { if (index > 0) topMargin = dp(8) })
            }
            column.addView(row, fullWidth(8))
        }
        column.addView(text("Camera challenges need a well-lit room. Turn on the room light; screen brightness stays unchanged.", 12f, SECONDARY).apply {
            setLeading(19.5f)
            setPadding(dp(8), 0, dp(8), 0)
        }, fullWidth(16))
        if ("tap" in escapes) {
            column.addView(iconButton(if (practice) "Finish practice" else "Stop alarm", R.drawable.wg_ic_task_alt, ACCENT, ON_ACCENT) { completeAlarm("tap") },
                LinearLayout.LayoutParams(-1, dp(56)).apply { topMargin = dp(24) })
        }
        if (practice) column.addView(iconButton("Exit practice", R.drawable.wg_ic_close, SURFACE, TEXT) { finishAndRemoveTask() },
            LinearLayout.LayoutParams(-1, dp(56)).apply { topMargin = dp(if ("tap" in escapes) 10 else 24) })
        return frame
    }

    private fun modeLabel(target: Mode) = when (target) {
        Mode.FACE -> "Face Verification"
        else -> target.title
    }

    private fun modeIcon(target: Mode) = when (target) {
        Mode.FACE -> R.drawable.wg_ic_face
        Mode.OBJECT -> R.drawable.wg_ic_focus
        Mode.QR -> R.drawable.wg_ic_qr
        Mode.TAP -> R.drawable.wg_ic_check_circle
    }

    private fun modeRow(target: Mode): ModeRow {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
            setPadding(dp(20), 0, dp(20), 0)
            isClickable = true
            isFocusable = true
            asButton(this)
            setOnClickListener { setMode(target) }
        }
        val icon = ImageView(this).apply {
            setImageResource(modeIcon(target))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        root.addView(icon, LinearLayout.LayoutParams(dp(24), dp(24)))
        val title = text(modeLabel(target), 16f, TEXT).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            typeface = labelFont
            letterSpacing = 0.01f
            setLeading(22f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        root.addView(title, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(12); marginEnd = dp(8) })
        val badge = labelText(if (practice) "PRACTICING" else "ACTIVE", ON_ACCENT, 0.04f).apply {
            background = rounded(Color.parseColor("#1A783316"), PILL)
            setPadding(dp(10), dp(4), dp(10), dp(4))
            setCompoundDrawablesRelative(null, null, glyph(R.drawable.wg_ic_check_circle, ON_ACCENT, 16), null)
            compoundDrawablePadding = dp(6)
        }
        root.addView(badge, LinearLayout.LayoutParams(-2, -2))
        val chevron = ImageView(this).apply {
            setImageResource(R.drawable.wg_ic_chevron_right)
            imageTintList = ColorStateList.valueOf(SECONDARY)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        root.addView(chevron, LinearLayout.LayoutParams(dp(20), dp(20)))
        return ModeRow(root, icon, title, badge, chevron)
    }

    private fun styleModeRow(row: ModeRow, selected: Boolean) {
        row.root.isSelected = selected
        row.root.background = pill(if (selected) ACCENT else SURFACE, if (selected) ON_ACCENT else TEXT)
        if (selected) glow(row.root) else row.root.elevation = dp(1).toFloat()
        row.icon.imageTintList = ColorStateList.valueOf(if (selected) ON_ACCENT else SECONDARY)
        row.title.setTextColor(if (selected) ON_ACCENT else TEXT)
        row.badge.visibility = if (selected) View.VISIBLE else View.GONE
        row.chevron.visibility = if (selected) View.GONE else View.VISIBLE
    }

    private fun renderStepDots() {
        if (!::stepDots.isInitialized) return
        stepDots.removeAllViews()
        val show = mode == Mode.FACE && !cameraUnavailable && actions.size > 1
        stepDots.visibility = if (show) View.VISIBLE else View.GONE
        if (!show) return
        actions.indices.forEach { index ->
            val current = index == actionIndex.coerceAtMost(actions.size - 1)
            val color = if (current) PEACH else HIGHEST
            stepDots.addView(View(this).apply { background = rounded(color, PILL) },
                LinearLayout.LayoutParams(dp(if (current) 16 else 6), dp(6)).apply { if (index > 0) marginStart = dp(4) })
        }
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
        previewBadge.text = when (next) { Mode.FACE -> "FRONT CAMERA • MIRROR VIEW"; Mode.OBJECT -> "REAR CAMERA • ${ObjectTargets.title(objectTarget).uppercase()}"; else -> "REAR CAMERA • QR SCAN" }
        instructionIcon.setImageResource(modeIcon(next))
        modeButtons.forEach { (target, control) -> styleModeRow(control, target == next) }
        // Only the challenge being worked on right now is active; the others are alternatives.
        activeCount?.text = "${modeButtons.keys.count { it == next }} Active"
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
        renderStepDots()
        previewContainer.visibility = if (mode != Mode.TAP && !cameraUnavailable) View.VISIBLE else View.GONE
        retryCamera.visibility = if (mode != Mode.TAP && cameraUnavailable) View.VISIBLE else View.GONE
        val currentAction = actions.getOrNull(actionIndex)
        guide.arrow = if (mode != Mode.FACE || cameraUnavailable) 0 else when (currentAction) {
            WakeAction.turnLeft -> -1
            WakeAction.turnRight -> 1
            else -> 0
        }
        // The design shows no bar for plain steps; keep it for timed holds and object tracking.
        progress.visibility = if (!cameraUnavailable && (mode == Mode.OBJECT ||
            (mode == Mode.FACE && currentAction == WakeAction.holdEyesOpen))) View.VISIBLE else View.GONE
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
        // onCreate can run before the lifecycle registry reaches STARTED. onStart and
        // onResume post a retry (startCameraWhenReady) once the view and lifecycle are ready.
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
            if (destroyed || challengeComplete) return@addListener
            if (!lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) {
                startCameraWhenReady()
                return@addListener
            }
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
        val countdownLabel = text("", 12f, MUTED)
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(32), dp(24), dp(28))
            background = rounded(SURFACE, 32)
            addView(labelText(if (practice) "PRACTICE COMPLETE" else "WAKE CHECK COMPLETE", SUCCESS, 0.05f))
            addView(ImageView(this@AlarmRingActivity).apply {
                setImageResource(R.drawable.wg_ic_check_circle)
                imageTintList = ColorStateList.valueOf(SUCCESS)
                scaleType = ImageView.ScaleType.CENTER_INSIDE
                setPadding(dp(20), dp(20), dp(20), dp(20))
                background = rounded(Color.parseColor("#1F00F1FD"), PILL)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(88), dp(88)).apply { topMargin = dp(24) })
            addView(text(if (practice) "You did it!" else "You're ready", 30f, TEXT).apply {
                typeface = headlineFont
                letterSpacing = -0.02f
                ViewCompat.setAccessibilityHeading(this, true)
            }, fullWidth(24))
            addView(text(detail, 16f, SECONDARY), fullWidth(12))
            if (quote != null) {
                addView(text("“$quote”", 17f, PEACH).apply {
                    setPadding(dp(18), dp(18), dp(18), dp(18))
                    background = rounded(ELEVATED, 24)
                    setLineSpacing(dp(4).toFloat(), 1f)
                }, fullWidth(20))
            }
            addView(primaryButton(if (practice) "Back to editor" else "Close") { finishAndRemoveTask() }, fullWidth(28))
            addView(countdownLabel, fullWidth(14))
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
        successCountdown = object : CountDownTimer(SUCCESS_CLOSE_DELAY_MS, 1000L) {
            override fun onTick(millisUntilFinished: Long) {
                if (destroyed || isFinishing) { cancel(); return }
                val seconds = ((millisUntilFinished + 999L) / 1000L).toInt()
                countdownLabel.text = resources.getQuantityString(R.plurals.success_auto_close, seconds, seconds)
            }
            override fun onFinish() {
                if (!destroyed && !isFinishing) finishAndRemoveTask()
            }
        }.start()
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
        text = title; isAllCaps = false; minimumHeight = dp(56); minHeight = dp(56)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = labelFont
        letterSpacing = 0.01f
        setTextColor(TEXT); background = pill(SURFACE, TEXT)
        stateListAnimator = null
        setPadding(dp(20), dp(12), dp(20), dp(12))
        setOnClickListener { action() }
    }
    private fun primaryButton(title: String, action: () -> Unit) = button(title, action).apply {
        background = pill(ACCENT, ON_ACCENT); setTextColor(ON_ACCENT)
        glow(this)
    }

    /** Pill button with a leading icon hugging its centered label (design "Finish/Exit practice"). */
    private fun iconButton(title: String, icon: Int, fill: Int, ink: Int, action: () -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = dp(56)
        setPadding(dp(20), 0, dp(20), 0)
        background = pill(fill, ink)
        isClickable = true
        isFocusable = true
        contentDescription = title
        asButton(this)
        if (fill == ACCENT) glow(this) else elevation = dp(1).toFloat()
        addView(ImageView(context).apply {
            setImageResource(icon)
            imageTintList = ColorStateList.valueOf(ink)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(20), dp(20)))
        addView(text(title, 16f, ink).apply {
            typeface = labelFont
            letterSpacing = 0.01f
            setLeading(22f)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(8) })
        setOnClickListener { action() }
    }

    private fun asButton(view: View) = ViewCompat.setAccessibilityDelegate(view, object : AccessibilityDelegateCompat() {
        override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfoCompat) {
            super.onInitializeAccessibilityNodeInfo(host, info)
            info.className = Button::class.java.name
        }
    })

    /** Colored glow under coral fills: shadow-[0_8px_24px_-2px_rgba(255,158,121,0.25)]. */
    private fun glow(view: View) {
        view.elevation = dp(8).toFloat()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            view.outlineSpotShadowColor = ACCENT
            view.outlineAmbientShadowColor = ACCENT
        }
    }

    private fun pill(fill: Int, ink: Int) = RippleDrawable(
        ColorStateList.valueOf((ink and 0x00FFFFFF) or 0x1F000000), rounded(fill, PILL), null)

    private fun text(value: String, size: Float, color: Int) = TextView(this).apply {
        text = value; setTextSize(TypedValue.COMPLEX_UNIT_SP, size); setTextColor(color); gravity = Gravity.CENTER
        typeface = bodyFont
    }

    /** label-sm: Inter 11sp semibold, 14sp line height. */
    private fun labelText(value: String, color: Int, tracking: Float) = text(value, 11f, color).apply {
        typeface = labelFont
        letterSpacing = tracking
        setLeading(14f)
    }

    private fun TextView.setLeading(sp: Float) = TextViewCompat.setLineHeight(this,
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics).toInt())

    private fun loadFont(res: Int, fallback: Typeface): Typeface =
        runCatching { ResourcesCompat.getFont(this, res) }.getOrNull() ?: fallback

    private fun rounded(color: Int, radius: Int = 24, stroke: Boolean = false) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
        if (stroke) setStroke(dp(1).coerceAtLeast(1), BORDER)
    }
    private fun dot(color: Int, size: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL; setColor(color); setBounds(0, 0, dp(size), dp(size))
    }
    private fun glyph(res: Int, color: Int, size: Int): Drawable? = ContextCompat.getDrawable(this, res)?.mutate()?.apply {
        setTint(color); setBounds(0, 0, dp(size), dp(size))
    }
    private fun fullWidth(top: Int = 0) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onStart() {
        super.onStart()
        if (::guide.isInitialized && !challengeComplete) guide.scanning = mode != Mode.TAP
        startCameraWhenReady()
    }
    override fun onResume() {
        super.onResume()
        AlarmChallengeLauncher.onResumed(this)
        startCameraWhenReady()
    }

    /**
     * The preview surface exists only once the window is attached (after onResume),
     * and the lifecycle registry can still be a step behind at that moment. Post the
     * bind until the view exists and gate on STARTED, which is all openCamera needs.
     * Gating on RESUMED dropped the only startup attempt, leaving the challenge idle
     * until a mode button was tapped again.
     */
    private fun startCameraWhenReady() {
        if (!::preview.isInitialized || destroyed || challengeComplete || mode == Mode.TAP) return
        preview.post {
            if (!destroyed && !challengeComplete &&
                lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) {
                openCamera(requestPermission = true)
            }
        }
    }
    internal fun isShowingSession(token: String): Boolean =
        !practice && !challengeComplete && sessionId == token

    override fun onPause() {
        AlarmChallengeLauncher.onPaused(this)
        super.onPause()
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
        successCountdown?.cancel()
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
