package com.bling.wakeguard

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Build
import android.provider.Settings
import android.view.View
import android.view.animation.LinearInterpolator

/** A framing guide, not a claimed detector bounding box. Does not alter brightness. */
class ChallengeGuideView(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f * resources.displayMetrics.density }
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = ACCENT }
    private val arrowFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arrowInk = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = ON_PRIMARY
        strokeWidth = 2f * resources.displayMetrics.density
        strokeCap = Paint.Cap.SQUARE; strokeJoin = Paint.Join.MITER
    }
    private val arrowPath = Path()
    private val haloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2.5f * resources.displayMetrics.density }
    private val centerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val scanBounds = RectF()
    private var faceCenterX = 0f
    private var faceCenterY = 0f
    private var faceRadius = 0f
    private var phase = 0f
    private var animator: ValueAnimator? = null
    private var animatedMotion = false
    var faceMode = false
        set(value) { field = value; invalidate() }
    /** Directional prompt on the reticle edge: -1 left, 1 right, 0 hidden. */
    var arrow = 0
        set(value) { if (field != value) { field = value; invalidate() } }
    var detected = false
        set(value) { if (field != value) { field = value; invalidate() } }
    var scanning = false
        set(value) { field = value; updateAnimation(); invalidate() }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO; isClickable = false }

    private fun updateAnimation() {
        animator?.cancel(); animator = null
        animatedMotion = motionAllowed(context)
        if (!scanning || !isAttachedToWindow || !animatedMotion) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1800L
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            interpolator = LinearInterpolator()
            addUpdateListener { phase = it.animatedValue as Float; invalidate() }
            start()
        }
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        scanBounds.set(width * 0.16f, height * 0.13f, width * 0.84f, height * 0.77f)
        faceCenterX = width / 2f
        faceCenterY = height / 2f
        // One radius for both axes: stays a circle on every preview aspect ratio.
        // The design reticle spans 4/5 of the square viewfinder, stroke drawn inside.
        faceRadius = minOf(width, height) * 0.4f - paint.strokeWidth / 2f
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val border = scanBounds
        val tone = if (detected) CYAN else PEACH
        paint.color = tone
        paint.alpha = if (detected) 255 else (190 + 65 * phase).toInt()
        if (faceMode) {
            val density = resources.displayMetrics.density
            glowPaint.strokeWidth = 14f * density
            glowPaint.color = if (detected) CYAN else ACCENT
            glowPaint.alpha = 22
            canvas.drawCircle(faceCenterX, faceCenterY, faceRadius, glowPaint)
            glowPaint.strokeWidth = 7f * density
            glowPaint.alpha = 34
            canvas.drawCircle(faceCenterX, faceCenterY, faceRadius, glowPaint)
            if (scanning && !detected && animatedMotion) {
                haloPaint.color = tone
                haloPaint.alpha = (70 * (1f - phase)).toInt()
                canvas.drawCircle(faceCenterX, faceCenterY, faceRadius + 10f * density * phase, haloPaint)
            }
            canvas.drawCircle(faceCenterX, faceCenterY, faceRadius, paint)
            centerPaint.color = tone
            centerPaint.alpha = 150
            canvas.drawCircle(faceCenterX, faceCenterY, 4f * density, centerPaint)
            if (arrow != 0) drawArrow(canvas, tone, density)
        } else {
            paint.strokeCap = Paint.Cap.ROUND
            val length = (border.width() * 0.15f).coerceAtMost(40f * resources.displayMetrics.density)
            canvas.drawLine(border.left, border.top + length, border.left, border.top, paint)
            canvas.drawLine(border.left, border.top, border.left + length, border.top, paint)
            canvas.drawLine(border.right - length, border.top, border.right, border.top, paint)
            canvas.drawLine(border.right, border.top, border.right, border.top + length, paint)
            canvas.drawLine(border.left, border.bottom - length, border.left, border.bottom, paint)
            canvas.drawLine(border.left, border.bottom, border.left + length, border.bottom, paint)
            canvas.drawLine(border.right - length, border.bottom, border.right, border.bottom, paint)
            canvas.drawLine(border.right, border.bottom, border.right, border.bottom - length, paint)
            if (scanning && !detected && animatedMotion) {
                paint.alpha = 100
                val y = border.top + border.height() * phase
                canvas.drawLine(border.left + length / 2, y, border.right - length / 2, y, paint)
            }
        }
    }

    private fun drawArrow(canvas: Canvas, tone: Int, density: Float) {
        // 32dp chip overlapping the reticle edge by 12dp, holding a 20dp arrow glyph.
        val cx = faceCenterX + arrow * (faceRadius + paint.strokeWidth / 2f - 4f * density)
        val bounce = if (scanning && !detected && animatedMotion) -6f * density * phase else 0f
        val cy = faceCenterY + bounce
        arrowFill.color = tone
        canvas.drawCircle(cx, cy, 16f * density, arrowFill)
        val unit = 20f * density / 24f
        val tipX = cx + arrow * 7f * unit
        arrowPath.reset()
        arrowPath.moveTo(cx - arrow * 7f * unit, cy)
        arrowPath.lineTo(tipX, cy)
        arrowPath.moveTo(cx, cy - 7f * unit)
        arrowPath.lineTo(tipX, cy)
        arrowPath.lineTo(cx, cy + 7f * unit)
        canvas.drawPath(arrowPath, arrowInk)
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); updateAnimation() }
    override fun onDetachedFromWindow() { animator?.cancel(); animator = null; super.onDetachedFromWindow() }

    companion object {
        private val PEACH = Color.parseColor("#FFC5B1")
        private val CYAN = Color.parseColor("#00F1FD")
        private val ACCENT = Color.parseColor("#FF9E79")
        private val ON_PRIMARY = Color.parseColor("#591D02")

        fun motionAllowed(context: Context): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ValueAnimator.areAnimatorsEnabled()
        } else Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    }
}
