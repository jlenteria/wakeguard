package com.bling.wakeguard

import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/** A Flutter-free check-in prompt. Showing it never extends or confirms the window. */
class StayAwakeActivity : AppCompatActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var alarmId = ""
    private var token: String? = null
    private lateinit var countdown: TextView
    private lateinit var progress: ProgressBar
    private lateinit var confirm: Button
    private lateinit var error: TextView

    private val tick = object : Runnable {
        override fun run() {
            if (refreshWindow()) main.postDelayed(this, 1_000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        alarmId = intent.getStringExtra(NativeAlarmScheduler.EXTRA_ALARM_ID).orEmpty()
        token = intent.getStringExtra(AlarmSessions.EXTRA_SESSION)
        val session = liveSession()
        if (session == null) {
            finishAndRemoveTask()
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val scroll = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(Color.parseColor("#10141A"))
        }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(28), dp(24), dp(28))
            background = rounded("#1C2026", 28, stroke = true)
        }
        card.addView(text("STAY AWAKE CHECK-IN", 12f, "#FF9F66").apply {
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = 0.08f
        }, fullWidth())
        card.addView(text("Still up?", 32f, "#DFE2EB").apply {
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = -0.02f
            ViewCompat.setAccessibilityHeading(this, true)
        }, fullWidth(20))
        card.addView(text(session.alarm.label, 18f, "#DAC1B9"), fullWidth(12))
        countdown = text("", 22f, "#FF9F66").apply { typeface = Typeface.DEFAULT_BOLD }
        card.addView(countdown, fullWidth(24))
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progressTintList = ColorStateList.valueOf(Color.parseColor("#FF9F66"))
            progressBackgroundTintList = ColorStateList.valueOf(Color.parseColor("#31353C"))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        card.addView(progress, fullWidth(12))
        card.addView(text("Confirm you’re still awake to prevent a follow-up alarm. Opening this page does not confirm the check-in.",
            16f, "#DAC1B9").apply { setLineSpacing(dp(3).toFloat(), 1f) }, fullWidth(20))
        error = text("", 15f, "#FFB4AB").apply { visibility = View.GONE }
        card.addView(error, fullWidth(12))
        confirm = Button(this).apply {
            text = "I'm up"
            isAllCaps = false
            minimumHeight = dp(56)
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            stateListAnimator = null
            setTextColor(Color.parseColor("#783316"))
            background = rounded("#FF9E79", 100)
            setOnClickListener { confirmCheckIn() }
        }
        card.addView(confirm, fullWidth(24))
        content.addView(card, fullWidth())
        scroll.addView(content)
        setContentView(scroll)
        ViewCompat.requestApplyInsets(scroll)
        refreshWindow()
    }

    private fun liveSession(): AlarmSession? {
        val session = AlarmSessions.get(this, alarmId) ?: return null
        return session.takeIf { token != null && it.token == token && it.phase == "checkin" &&
            StayAwake.windowOpen(it) }
    }

    private fun refreshWindow(): Boolean {
        if (isFinishing || isDestroyed) return false
        val session = liveSession()
        if (session == null) {
            finishAndRemoveTask()
            return false
        }
        val remaining = (StayAwake.deadline(session) - System.currentTimeMillis())
            .coerceIn(0L, StayAwake.GRACE_MS)
        countdown.text = "${(remaining + 999L) / 1000L} seconds remaining"
        progress.progress = (remaining * 1000L / StayAwake.GRACE_MS).toInt()
        return true
    }

    private fun confirmCheckIn() {
        confirm.isEnabled = false
        runCatching { StayAwake.confirm(this, alarmId, token) }
            .onSuccess { confirmed ->
                if (confirmed) Toast.makeText(this, "Check-in confirmed. Have a good morning!", Toast.LENGTH_SHORT).show()
                finishAndRemoveTask()
            }.onFailure {
                android.util.Log.e("WakeGuard", "Check-in confirmation failed", it)
                if (refreshWindow()) {
                    confirm.isEnabled = true
                    error.text = "Could not confirm. Please try again."
                    error.visibility = View.VISIBLE
                    error.announceForAccessibility(error.text)
                }
            }
    }

    override fun onResume() {
        super.onResume()
        AlarmChallengeLauncher.onResumed(this)
        main.removeCallbacks(tick)
        if (::countdown.isInitialized) tick.run()
    }

    override fun onPause() {
        AlarmChallengeLauncher.onPaused(this)
        main.removeCallbacks(tick)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recreate()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun fullWidth(top: Int = 0) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun rounded(color: String, radius: Int, stroke: Boolean = false) = GradientDrawable().apply {
        setColor(Color.parseColor(color))
        cornerRadius = dp(radius).toFloat()
        if (stroke) setStroke(dp(1).coerceAtLeast(1), Color.parseColor("#14FFFFFF"))
    }
    private fun text(value: String, size: Float, color: String) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(Color.parseColor(color))
        gravity = Gravity.CENTER
    }
}
