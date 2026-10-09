package app.wakeguard

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.CountDownTimer
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Space
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
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import java.util.Random
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The native wake challenge.
 *
 * This is deliberately a plain Android Activity rather than a Flutter route.
 * Dismissing a live alarm must not depend on the Flutter engine booting, a Dart
 * isolate surviving, or a plugin resolving: a Dart crash at 05:00 would
 * otherwise leave a user staring at a screen they cannot leave.
 *
 * Four independent escapes exist and any one of them completes the alarm:
 *
 *  1. Face actions (camera) - the "you are actually awake" check.
 *  2. A remembered pattern sequence - no camera, no light, fully accessible.
 *  3. A QR code away from bed - the physical nudge.
 *  4. A deliberate two minute hold - always available, never conditional.
 *
 * The invariant is that no single failing subsystem can trap the user. If the
 * camera is broken, denied, or facing a dark room, escapes 2 and 4 still work.
 */
class AlarmRingActivity : AppCompatActivity() {

    private enum class Mode { TAP, FACE, PATTERN, QR }

    private val random = Random()
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private lateinit var previewView: PreviewView
    private lateinit var instructionLabel: TextView
    private lateinit var stepLabel: TextView
    private lateinit var statusLabel: TextView
    private lateinit var patternGrid: GridLayout
    private lateinit var torchButton: Button

    private var faceDetector: com.google.mlkit.vision.face.FaceDetector? = null
    private var barcodeScanner: com.google.mlkit.vision.barcode.BarcodeScanner? = null
    private val analyzing = AtomicBoolean(false)
    @Volatile private var analysisGeneration = 0
    private var cameraStarting = false
    @Volatile private var destroyed = false
    private var practice = false
    private var sessionId: String? = null

    private var cameraProvider: ProcessCameraProvider? = null
    private var boundCamera: androidx.camera.core.Camera? = null
    @Volatile private var mode = Mode.FACE
    private var actions: List<WakeAction> = emptyList()
    private var actionIndex = 0
    private var pendingQr = ""

    /** Escapes this alarm offers, as read from the launch intent. */
    private var escapes: Set<String> = AlarmDefaults.ALL_ESCAPES

    /** Difficulty-derived step count (1-3); also sizes the pattern sequence. */
    private var stepCount: Int = 2

    private var holdButton: Button? = null

    private val patternCells = mutableListOf<Button>()
    private var patternSequence: List<Int> = emptyList()
    private var patternInputIndex = 0
    private var patternShowing = false
    private val patternHandler = Handler(Looper.getMainLooper())

    /** Id of the ringing alarm; required to re-arm exactly this alarm. */
    private var alarmId: String = ""
    private var challengeComplete = false

    /**
     * Registered as [RingingState.onStopped] so a snooze can close this screen.
     * Identity-compared on the way out so a later instance's listener is not
     * cleared by this one's teardown.
     */
    private val stopListener: () -> Unit = {
        runOnUiThread {
            if (!practice && !challengeComplete && RingingState.sessionId == sessionId) finishAndRemoveTask()
        }
    }

    private var eyesWereClosed = false
    private var blinkCount = 0
    private var holdStartedAt = 0L
    private var lastAnalysisAt = 0L
    private var torchOn = false
    private var cameraUnavailable = false

    private companion object {
        const val ANALYSIS_INTERVAL_MS = 120L
        const val ESCAPE_HOLD_MS = 2 * 60_000L
        const val BLINK_EYE_THRESHOLD = 0.28f
        const val OPEN_EYE_THRESHOLD = 0.72f
        const val SMILE_THRESHOLD = 0.72f
        const val HEAD_YAW_THRESHOLD = 22f
        const val REQUEST_CAMERA = 4321

        /** Each pattern cell is lit this long, with this gap between steps. */
        const val PATTERN_FLASH_ON_MS = 450L
        const val PATTERN_FLASH_GAP_MS = 250L

        val CELL_OFF = Color.parseColor("#263238")
        val CELL_ON = Color.parseColor("#FFB74D")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        practice = intent.getBooleanExtra("practice", false)
        sessionId = intent.getStringExtra(AlarmSessions.EXTRA_SESSION)
        if (!practice) {
            val id = intent.getStringExtra(NativeAlarmScheduler.EXTRA_ALARM_ID).orEmpty()
            val session = AlarmSessions.get(this, id)
            if (session == null || session.token != sessionId || session.phase != "ringing") {
                finishAndRemoveTask()
                return
            }
        }
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
        )
        // A stray back gesture must not dismiss a live alarm.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { if (practice) finishAndRemoveTask() }
        })

        // Read once: the launch intent is the only copy of the ringing alarm id,
        // and re-reading `intent` after a rebind can return a different launch
        // intent on some OEM builds, which previously left the id missing.
        alarmId = intent.getStringExtra(NativeAlarmScheduler.EXTRA_ALARM_ID).orEmpty()
        pendingQr = intent.getStringExtra(NativeAlarmScheduler.EXTRA_QR).orEmpty()
        stepCount = intent.getIntExtra(NativeAlarmScheduler.EXTRA_STEPS, 2)
        escapes = AlarmDefaults.escapesFromExtra(
            intent.getStringExtra(NativeAlarmScheduler.EXTRA_ESCAPES),
        )
        // Face actions only exist when the alarm actually offers the face
        // escape; with it turned off the camera would otherwise still be able
        // to complete a challenge the user chose not to set.
        actions = if (escapes.contains(AlarmDefaults.ESCAPE_FACE)) {
            pickActions(stepCount)
        } else {
            emptyList()
        }
        mode = initialMode() ?: Mode.FACE

        setContentView(buildLayout())
        updateInstructions()

        // A snooze tapped in the notification must close this screen too:
        // leaving a challenge up for an alarm that is no longer ringing let
        // the user "complete" an alarm they had already surrendered.
        if (!practice) RingingState.onStopped = stopListener

        // Applies the starting mode's visibility and asks for the camera only
        // when this alarm's chosen escapes actually use one: a pattern-only
        // alarm must not trigger a permission prompt it will never need.
        setMode(mode)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recreate()
    }

    /**
     * The mode this alarm starts in, or null when only the hold escape works.
     *
     * Null is possible when a QR escape has no code to scan — a record a
     * newer build wrote, or one restored from a partial backup. The activity
     * still opens, showing only the hold button, rather than failing to start
     * on an alarm that is ringing.
     */
    private fun initialMode(): Mode? = when {
        escapes.contains(AlarmDefaults.ESCAPE_TAP) -> Mode.TAP
        escapes.contains(AlarmDefaults.ESCAPE_FACE) -> Mode.FACE
        escapes.contains(AlarmDefaults.ESCAPE_PATTERN) -> Mode.PATTERN
        escapes.contains(AlarmDefaults.ESCAPE_QR) && pendingQr.isNotEmpty() -> Mode.QR
        else -> null
    }

    /**
     * A random subset of actions, guaranteeing at least one that needs real head
     * or eye movement so the challenge cannot be passed from bed.
     */
    private fun pickActions(count: Int): List<WakeAction> {
        val pool = WakeAction.entries.toMutableList()
        pool.shuffle(random)
        val picked = pool.take(count.coerceIn(1, WakeAction.entries.size)).toMutableList()
        if (picked.all { it == WakeAction.holdEyesOpen }) {
            picked[picked.lastIndex] = WakeAction.turnLeft
        }
        return picked
    }

    // region UI

    private fun buildLayout(): View {
        val root = ScrollView(this).apply {
            setBackgroundColor(Color.BLACK)
            isFillViewport = true
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(28), dp(20), dp(28))
        }
        root.addView(
            column,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        column.addView(
            TextView(this).apply {
                text = intent.getStringExtra(NativeAlarmScheduler.EXTRA_LABEL) ?: "Wake up"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
            },
        )
        column.addView(spacer(12))

        instructionLabel = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        column.addView(instructionLabel)

        stepLabel = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(Color.LTGRAY)
            gravity = Gravity.CENTER
        }
        column.addView(stepLabel)
        column.addView(spacer(12))

        statusLabel = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(Color.parseColor("#FFB74D"))
            gravity = Gravity.CENTER
        }
        column.addView(statusLabel)
        column.addView(spacer(12))

        previewView = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        column.addView(
            previewView,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(240)),
        )

        patternGrid = buildPatternGrid()
        patternGrid.visibility = View.GONE
        column.addView(patternGrid)

        torchButton = modeButton(getString(R.string.action_torch)) { toggleTorch() }
        column.addView(spacer(12))

        val modeRow = GridLayout(this).apply { columnCount = 2; useDefaultMargins = true }
        fun addMode(button: Button) {
            val index = modeRow.childCount
            modeRow.addView(button, GridLayout.LayoutParams(
                GridLayout.spec(index / 2), GridLayout.spec(index % 2, 1f)).apply {
                width = 0; height = ViewGroup.LayoutParams.WRAP_CONTENT
            })
        }
        // Only the escapes this alarm was configured with are offered. The
        // hold button below is not conditional: it is the one way out that
        // never depends on a subsystem succeeding.
        if (escapes.contains(AlarmDefaults.ESCAPE_TAP)) {
            addMode(modeButton("Stop alarm") { completeAlarm("tap") })
        }
        if (escapes.contains(AlarmDefaults.ESCAPE_FACE)) {
            addMode(modeButton("Face") { setMode(Mode.FACE) })
        }
        if (escapes.contains(AlarmDefaults.ESCAPE_PATTERN)) {
            addMode(modeButton("Pattern") { setMode(Mode.PATTERN) })
        }
        if (escapes.contains(AlarmDefaults.ESCAPE_QR) && pendingQr.isNotEmpty()) {
            addMode(modeButton("QR") { setMode(Mode.QR) })
        }
        addMode(torchButton)
        column.addView(modeRow)

        column.addView(spacer(16))
        // Escape hatch: always present, never conditional on any other
        // subsystem succeeding.
        column.addView(
            buildHoldToStopButton(),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(76)),
        )
        column.addView(spacer(8))
        if (practice) column.addView(modeButton("Exit practice") { finishAndRemoveTask() })
        return root
    }

    private fun modeButton(label: String, onTap: () -> Unit): Button = Button(this).apply {
        text = label
        isAllCaps = false
        setOnClickListener { onTap() }
    }

    private fun buildHoldToStopButton(): Button = Button(this).apply {
        text = getString(R.string.hold_to_stop)
        isAllCaps = false
        setBackgroundColor(Color.parseColor("#B71C1C"))
        setOnClickListener { /* hold only; a plain tap must do nothing */ }
        setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    val startedAt = android.os.SystemClock.elapsedRealtime()
                    val button = view as Button
                    // The button must stay enabled while held. A disabled view
                    // stops delivering touch events to this listener, so the
                    // ACTION_UP below never arrived and the countdown kept
                    // running after the finger lifted.
                    (view.tag as? CountDownTimer)?.cancel()
                    view.tag = object : CountDownTimer(ESCAPE_HOLD_MS, 100) {
                        override fun onTick(millisUntilFinished: Long) {
                            val held = android.os.SystemClock.elapsedRealtime() - startedAt
                            button.alpha = 0.5f + 0.5f * (held / ESCAPE_HOLD_MS.toFloat())
                            // Minutes:seconds, because a raw "112 s" is one
                            // more thing to parse at 05:00.
                            val remaining = ((ESCAPE_HOLD_MS - held) / 1000).toInt()
                            button.text = getString(
                                R.string.hold_to_stop_progress,
                                "%d:%02d".format(remaining / 60, remaining % 60),
                            )
                        }

                        override fun onFinish() {
                            button.alpha = 1f
                            button.text = getString(R.string.hold_to_stop)
                            completeAlarm("hold")
                        }
                    }.also { it.start() }
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    (view.tag as? CountDownTimer)?.cancel()
                    view.tag = null
                    view.alpha = 1f
                    (view as Button).text = getString(R.string.hold_to_stop)
                }
            }
            true
        }
        holdButton = this
    }

    /** Releases the hold if the screen is left mid-press, since no UP will come. */
    override fun onStop() {
        analysisGeneration++
        patternHandler.removeCallbacksAndMessages(null)
        patternShowing = false
        runCatching { cameraProvider?.unbindAll() }
        holdButton?.let { button ->
            (button.tag as? CountDownTimer)?.cancel()
            button.tag = null
            button.alpha = 1f
            button.text = getString(R.string.hold_to_stop)
        }
        super.onStop()
    }

    override fun onStart() {
        super.onStart()
        if (::patternGrid.isInitialized && mode == Mode.PATTERN) rollPattern()
        if (::previewView.isInitialized && mode != Mode.PATTERN && cameraModeReachable() && hasCameraPermission()) startCamera()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun spacer(heightDp: Int): Space =
        Space(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(heightDp),
            )
        }

    // endregion

    // region mode

    private fun setMode(next: Mode) {
        analysisGeneration++
        mode = next
        // Cancel any in-flight flash: its end callback would otherwise stamp
        // pattern copy onto the face or QR screen after a mode switch.
        patternHandler.removeCallbacksAndMessages(null)
        patternShowing = false
        val patternMode = next == Mode.PATTERN
        // A camera never gets a preview or a torch button when this alarm's
        // escapes do not offer one: a black rectangle over "hold to stop" is
        // one more thing to misread at 05:00.
        val showsCamera = (next == Mode.FACE || next == Mode.QR) && cameraModeReachable()
        patternGrid.visibility = if (patternMode) View.VISIBLE else View.GONE
        previewView.visibility = if (showsCamera) View.VISIBLE else View.GONE
        torchButton.visibility = if (showsCamera) View.VISIBLE else View.GONE
        setStatus("")
        updateInstructions()
        // The camera is acquired lazily rather than in onCreate, so a
        // pattern-only alarm never asks for a permission it will not use and
        // the first switch to a camera mode still gets one.
        if (showsCamera && cameraProvider == null) {
            if (hasCameraPermission()) {
                startCamera()
            } else {
                requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQUEST_CAMERA)
            }
        } else {
            rebindAnalysis()
        }
        if (patternMode) rollPattern()
    }

    /** Whether any escape this alarm offers is analysed through the camera. */
    private fun cameraModeReachable(): Boolean =
        escapes.contains(AlarmDefaults.ESCAPE_FACE) ||
            (escapes.contains(AlarmDefaults.ESCAPE_QR) && pendingQr.isNotEmpty())

    private fun buildPatternGrid(): GridLayout {
        val grid = GridLayout(this).apply {
            columnCount = 3
            rowCount = 3
        }
        for (index in 0..8) {
            val cell = Button(this).apply {
                text = (index + 1).toString()
                paintCell(this, on = false)
                setOnClickListener { onPatternCell(index) }
            }
            cell.layoutParams = GridLayout.LayoutParams(
                GridLayout.spec(index / 3),
                GridLayout.spec(index % 3),
            ).apply {
                width = ((resources.displayMetrics.widthPixels - dp(76)) / 3).coerceAtLeast(dp(48))
                height = dp(88)
                setMargins(dp(6), dp(6), dp(6), dp(6))
            }
            patternCells.add(cell)
            cell.contentDescription = "Pattern cell ${index + 1}"
            grid.addView(cell)
        }
        return grid
    }

    /**
     * Rolls a fresh sequence and flashes it.
     *
     * The length comes from the alarm's difficulty (4-6 cells), so the strict
     * preset demands one more step of working memory than the gentle one. The
     * sequence never repeats the same cell twice in a row: a doubled cell is a
     * no-op flash that wastes a step without adding any difficulty.
     */
    private fun rollPattern() {
        val length = (3 + stepCount).coerceIn(4, 6)
        val sequence = ArrayList<Int>(length)
        while (sequence.size < length) {
            val next = random.nextInt(9)
            if (sequence.isNotEmpty() && sequence.last() == next) continue
            sequence.add(next)
        }
        patternSequence = sequence
        patternInputIndex = 0
        flashPattern()
    }

    private fun flashPattern() {
        patternShowing = true
        patternHandler.removeCallbacksAndMessages(null)
        patternCells.forEach {
            paintCell(it, on = false)
            it.isEnabled = false
        }
        patternSequence.forEachIndexed { order, cell ->
            val onAt = order * (PATTERN_FLASH_ON_MS + PATTERN_FLASH_GAP_MS)
            patternHandler.postDelayed({
                paintCell(patternCells[cell], on = true)
                patternCells[cell].announceForAccessibility("${cell + 1}")
            }, onAt)
            patternHandler.postDelayed(
                { paintCell(patternCells[cell], on = false) },
                onAt + PATTERN_FLASH_ON_MS,
            )
        }
        patternHandler.postDelayed(
            {
                patternShowing = false
                patternCells.forEach { it.isEnabled = true }
                setStatus(getString(R.string.pattern_repeat))
                updateInstructions()
            },
            patternSequence.size * (PATTERN_FLASH_ON_MS + PATTERN_FLASH_GAP_MS),
        )
    }

    /**
     * Input half of the pattern challenge. A wrong cell does not just re-roll:
     * it immediately replays a full sequence, so guessing the next tap is never
     * rewarded with a step of progress.
     */
    private fun onPatternCell(index: Int) {
        if (challengeComplete || patternShowing) return
        if (index == patternSequence.getOrNull(patternInputIndex)) {
            patternInputIndex++
            paintCell(patternCells[index], on = true)
            patternHandler.postDelayed({ paintCell(patternCells[index], on = false) }, 160)
            if (patternInputIndex >= patternSequence.size) {
                completeAlarm("pattern")
                return
            }
            updateInstructions()
            return
        }
        setStatus(getString(R.string.pattern_wrong))
        rollPattern()
    }

    private fun paintCell(cell: Button, on: Boolean) {
        cell.setBackgroundColor(if (on) CELL_ON else CELL_OFF)
    }

    private fun updateInstructions() {
        if (cameraUnavailable && (mode == Mode.FACE || mode == Mode.QR)) {
            instructionLabel.text = getString(R.string.camera_unavailable)
            stepLabel.text = if (escapes.contains(AlarmDefaults.ESCAPE_PATTERN)) getString(R.string.use_pattern_escape)
                else getString(R.string.only_hold_escape)
            return
        }
        when (mode) {
            Mode.TAP -> {
                instructionLabel.text = if (practice) "Try stopping the alarm" else "Good morning"
                stepLabel.text = "Tap Stop alarm when you're ready"
            }
            Mode.FACE -> {
                if (cameraUnavailable) {
                    instructionLabel.text = getString(R.string.camera_unavailable)
                    // Point at an escape this alarm actually offers: telling
                    // someone to use the pattern on an alarm that has none is
                    // advice they cannot act on.
                    stepLabel.text = if (escapes.contains(AlarmDefaults.ESCAPE_PATTERN)) {
                        getString(R.string.use_pattern_escape)
                    } else {
                        getString(R.string.only_hold_escape)
                    }
                    return
                }
                if (actions.isEmpty()) {
                    // Face is off and no other mode was reachable: the screen
                    // exists only to offer the hold button below.
                    instructionLabel.text = getString(R.string.only_hold_escape)
                    stepLabel.text = ""
                    return
                }
                val action = actions[actionIndex.coerceIn(0, actions.size - 1)]
                instructionLabel.text = action.instruction
                stepLabel.text = getString(
                    R.string.step_counter,
                    actionIndex + 1,
                    actions.size,
                )
            }

            Mode.PATTERN -> {
                instructionLabel.text = getString(R.string.pattern_instruction)
                stepLabel.text = getString(
                    R.string.pattern_progress,
                    patternInputIndex,
                    patternSequence.size,
                )
            }

            Mode.QR -> {
                instructionLabel.text = getString(R.string.qr_instruction)
                stepLabel.text = getString(R.string.get_up_and_find_it)
            }
        }
    }

    private fun setStatus(text: String) {
        statusLabel.text = text
    }

    // endregion

    // region camera

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /**
     * Face recognition needs the front camera; a QR code on a printed card is
     * held up to the rear camera. Picking the wrong one for the mode makes the
     * challenge impossible, so the lens follows [mode]. [rebindAnalysis] is
     * invoked on every mode change, which is what actually swaps the camera.
     */
    private fun cameraSelector(): CameraSelector =
        if (mode == Mode.QR) CameraSelector.DEFAULT_BACK_CAMERA
        else CameraSelector.DEFAULT_FRONT_CAMERA

    private fun startCamera() {
        if (cameraStarting || destroyed || (mode != Mode.FACE && mode != Mode.QR) || !cameraModeReachable()) return
        cameraStarting = true
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            cameraStarting = false
            if (destroyed || (mode != Mode.FACE && mode != Mode.QR) || !lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) return@addListener
            runCatching { bindCamera(future.get()) }
                .onFailure {
                    cameraUnavailable = true
                    setStatus(getString(R.string.camera_failed))
                    updateInstructions()
                }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun bindCamera(provider: ProcessCameraProvider) {
        if (destroyed || (mode != Mode.FACE && mode != Mode.QR)) return
        if (mode == Mode.FACE && faceDetector == null) faceDetector = FaceDetection.getClient(
            FaceDetectorOptions.Builder().setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL).build())
        if (mode == Mode.QR && barcodeScanner == null) barcodeScanner = BarcodeScanning.getClient()
        cameraUnavailable = false
        cameraProvider = provider
        provider.unbindAll()
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }
        val analysis = ImageAnalysis.Builder()
            .setTargetResolution(android.util.Size(640, 480))
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { it.setAnalyzer(analysisExecutor) { proxy -> analyze(proxy) } }
        boundCamera = provider.bindToLifecycle(this, cameraSelector(), preview, analysis)
        boundCamera?.cameraControl?.enableTorch(torchOn)
        updateInstructions()
    }

    private fun rebindAnalysis() {
        val provider = cameraProvider ?: return
        if (mode != Mode.FACE && mode != Mode.QR) {
            runCatching { provider.unbindAll() }
            return
        }
        runCatching { bindCamera(provider) }.onFailure {
            cameraUnavailable = true
            setStatus(getString(R.string.camera_failed))
            updateInstructions()
        }
    }

    /**
     * The torch is the mitigation for a dark bedroom, which is the single most
     * likely way a face or QR challenge fails at 05:00. It rides whichever
     * camera the current mode is using (front for face, rear for QR).
     */
    private fun toggleTorch() {
        if (boundCamera?.cameraInfo?.hasFlashUnit() != true) {
            setStatus("No torch on this camera. Try more light or another escape.")
            return
        }
        torchOn = !torchOn
        runCatching { boundCamera?.cameraControl?.enableTorch(torchOn) }
        setStatus(if (torchOn) getString(R.string.torch_on) else "")
    }

    /**
     * Throttled analysis. Running ML Kit on every frame at 640x480 alongside a
     * foreground service and looping audio caused thermal throttling, which
     * itself raises the odds of the service being killed.
     */
    private fun analyze(proxy: ImageProxy) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastAnalysisAt < ANALYSIS_INTERVAL_MS || challengeComplete || destroyed || (mode != Mode.FACE && mode != Mode.QR) || !analyzing.compareAndSet(false, true)) {
            proxy.close()
            return
        }
        lastAnalysisAt = now
        val media = proxy.image
        if (media == null) {
            analyzing.set(false)
            proxy.close()
            return
        }
        try {
        val image = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
        val generation = analysisGeneration

        if (mode == Mode.QR) {
            val scanner = barcodeScanner ?: run { proxy.close(); analyzing.set(false); return }
            scanner.process(image)
                .addOnSuccessListener { codes ->
                    val matched = codes.any { it.rawValue?.trim() == pendingQr.trim() }
                    runOnUiThread {
                        if (destroyed || generation != analysisGeneration || mode != Mode.QR) return@runOnUiThread
                        if (matched) completeAlarm("qr") else setStatus(getString(R.string.wrong_code))
                    }
                }
                .addOnCompleteListener { proxy.close(); analyzing.set(false) }
            return
        }

        val detector = faceDetector ?: run { proxy.close(); analyzing.set(false); return }
        detector.process(image)
            .addOnSuccessListener { faces ->
                runOnUiThread {
                if (destroyed || generation != analysisGeneration || mode != Mode.FACE) return@runOnUiThread
                when {
                    faces.isEmpty() -> runOnUiThread {
                        setStatus(getString(R.string.no_face_found))
                    }

                    faces.size > 1 -> runOnUiThread {
                        setStatus(getString(R.string.more_than_one_face))
                    }

                    else -> evaluateFace(faces.first())
                }
                }
            }
            .addOnCompleteListener { proxy.close(); analyzing.set(false) }
        } catch (failure: Exception) {
            proxy.close()
            analyzing.set(false)
            android.util.Log.w("WakeGuard", "Camera frame could not be analysed", failure)
        }
    }

    private fun evaluateFace(face: Face) {
        // Empty when the face escape is off for this alarm: the mode cannot be
        // reached from the UI, but the analyzer may still deliver one frame
        // after a switch, and indexing into an empty list would crash it.
        if (challengeComplete || actions.isEmpty() || mode != Mode.FACE) return
        val leftOpen = face.leftEyeOpenProbability ?: 1f
        val rightOpen = face.rightEyeOpenProbability ?: 1f
        val bothClosed = leftOpen < BLINK_EYE_THRESHOLD && rightOpen < BLINK_EYE_THRESHOLD
        val bothOpen = leftOpen > OPEN_EYE_THRESHOLD && rightOpen > OPEN_EYE_THRESHOLD
        val smiling = face.smilingProbability ?: 0f
        val yaw = face.headEulerAngleY ?: 0f

        var passed = false
        when (actions[actionIndex.coerceIn(0, actions.size - 1)]) {
            WakeAction.blinkTwice -> {
                if (bothClosed) eyesWereClosed = true
                if (eyesWereClosed && bothOpen) {
                    blinkCount++
                    eyesWereClosed = false
                    passed = blinkCount >= 2
                }
            }

            WakeAction.smile -> passed = smiling > SMILE_THRESHOLD

            WakeAction.turnLeft -> passed = yaw < -HEAD_YAW_THRESHOLD
            WakeAction.turnRight -> passed = yaw > HEAD_YAW_THRESHOLD

            WakeAction.holdEyesOpen -> {
                if (bothOpen) {
                    if (holdStartedAt == 0L) holdStartedAt = android.os.SystemClock.elapsedRealtime()
                    val held = android.os.SystemClock.elapsedRealtime() - holdStartedAt
                    runOnUiThread {
                        setStatus(getString(R.string.keep_eyes_open, (5 - held / 1000).coerceAtLeast(0)))
                    }
                    passed = held >= 5_000L
                } else {
                    holdStartedAt = 0L
                }
            }
        }
        if (passed) advanceAction()
    }

    private fun advanceAction() {
        runOnUiThread {
            if (challengeComplete) return@runOnUiThread
            actionIndex++
            blinkCount = 0
            eyesWereClosed = false
            holdStartedAt = 0L
            setStatus("")
            if (actionIndex >= actions.size) {
                completeAlarm("face")
            } else {
                updateInstructions()
            }
        }
    }

    // endregion

    private fun completeAlarm(method: String) {
        if (challengeComplete) return
        challengeComplete = true
        Toast.makeText(this, if (practice) "Practice complete" else getString(R.string.alarm_dismissed), Toast.LENGTH_SHORT).show()
        if (!practice) {
            try { AlarmDismissal.complete(this, alarmId, method, sessionId) }
            catch (failure: Exception) {
                challengeComplete = false
                setStatus("Could not finish the alarm. Please try again.")
                android.util.Log.e("WakeGuard", "Dismissal failed", failure)
                return
            }
        }
        finishAndRemoveTask()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CAMERA) return
        // The pattern screen never uses the camera; a late answer to a prompt
        // raised on another mode must not stamp a camera status onto it. The
        // flag is still set below when the user switches and is asked again.
        if (mode != Mode.FACE && mode != Mode.QR) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) {
            startCamera()
        } else {
            cameraUnavailable = true
            setStatus(getString(R.string.camera_denied))
            updateInstructions()
        }
    }

    override fun onDestroy() {
        destroyed = true
        analysisGeneration++
        if (RingingState.onStopped === stopListener) RingingState.onStopped = null
        patternHandler.removeCallbacksAndMessages(null)
        runCatching { cameraProvider?.unbindAll() }
        runCatching { faceDetector?.close() }
        runCatching { barcodeScanner?.close() }
        analysisExecutor.shutdown()
        super.onDestroy()
    }
}

/** The five face actions, mirroring the Dart `WakeAction` enum. */
enum class WakeAction(val instruction: String) {
    blinkTwice("Blink twice"),
    smile("Smile"),
    turnLeft("Turn your head left"),
    turnRight("Turn your head right"),
    holdEyesOpen("Hold your eyes open"),
}
/**
 * Shared builders for the intents that launch the challenge, so the scheduler
 * and the service cannot drift apart on intent construction.
 */
object AlarmIntents {

    fun ringActivity(context: Context, alarm: StoredAlarm): Intent =
        Intent(context, AlarmRingActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            putExtra(NativeAlarmScheduler.EXTRA_ALARM_ID, alarm.id)
            putExtra(NativeAlarmScheduler.EXTRA_LABEL, alarm.label)
            putExtra(NativeAlarmScheduler.EXTRA_QR, alarm.qrValue)
            putExtra(NativeAlarmScheduler.EXTRA_STEPS, alarm.stepCount)
            putExtra(NativeAlarmScheduler.EXTRA_ESCAPES, NativeAlarmScheduler.escapesExtra(alarm))
            putExtra(AlarmSessions.EXTRA_SESSION, AlarmSessions.get(context, alarm.id)?.token)
            data = android.net.Uri.parse("wakeguard://ring/${alarm.id}/${AlarmSessions.get(context, alarm.id)?.token}")
        }
}
