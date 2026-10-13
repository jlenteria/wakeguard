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
    private val faceMaskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#55000000") }
    private val faceMask = Path()
    private val scanBounds = RectF()
    private var faceCenterX = 0f
    private var faceCenterY = 0f
    private var faceRadius = 0f
    private var phase = 0f
    private var animator: ValueAnimator? = null
    private var animatedMotion = false
    var faceMode = false
        set(value) { field = value; invalidate() }
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
        faceCenterY = height * 0.45f
        // One radius for both axes: stays a circle on every preview aspect ratio.
        faceRadius = minOf(width * 0.34f, height * 0.32f)
        faceMask.reset()
        faceMask.fillType = Path.FillType.EVEN_ODD
        faceMask.addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
        faceMask.addCircle(faceCenterX, faceCenterY, faceRadius, Path.Direction.CW)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val border = scanBounds
        paint.color = if (detected) Color.parseColor("#8FE0B3") else Color.parseColor("#FF9B70")
        paint.alpha = if (detected) 255 else (150 + 80 * phase).toInt()
        if (faceMode) {
            canvas.drawPath(faceMask, faceMaskPaint)
            canvas.drawCircle(faceCenterX, faceCenterY, faceRadius, paint)
        } else {
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

    override fun onAttachedToWindow() { super.onAttachedToWindow(); updateAnimation() }
    override fun onDetachedFromWindow() { animator?.cancel(); animator = null; super.onDetachedFromWindow() }

    companion object {
        fun motionAllowed(context: Context): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ValueAnimator.areAnimatorsEnabled()
        } else Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    }
}
