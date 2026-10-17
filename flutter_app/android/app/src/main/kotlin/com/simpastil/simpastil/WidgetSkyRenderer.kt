package com.simpastil.simpastil

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import java.time.LocalDate
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Draws the widget's sky header and the row capsules into bitmaps for
 * RemoteViews. Geometry follows the Flutter HorizonPainter at widget scale.
 * Everything is a static frame: the widget never animates.
 */
internal object WidgetSkyRenderer {
    private const val MARK_TILT_DEG = -31.5f // HorizonModel.markTilt (-0.55 rad)
    private val golden = 0xFFFFC27A.toInt()
    private val rose = 0xFFFFA283.toInt()
    private val paleSun = 0xFFFFE7B3.toInt()
    private val paleDawnSun = 0xFFFFD6BC.toInt()

    /** Largest bitmap scale; keeps a 5x5 widget well under the RemoteViews budget. */
    private const val MAX_SCALE = 2.0f

    fun scaleFor(density: Float): Float = min(density, MAX_SCALE)

    fun renderSky(
        widthDp: Int,
        heightDp: Int,
        density: Float,
        colors: WidgetColors,
        date: LocalDate,
        minute: Double,
        marks: List<SkyMark>,
        tier: WidgetTier,
        cornerDp: Float = 24f,
    ): Bitmap {
        val s = scaleFor(density)
        val w = max(1, (widthDp * s).toInt())
        val h = max(1, (heightDp * s).toInt())
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val wf = w.toFloat()
        val hf = h.toFloat()
        val dp = s
        val dark = colors.dark

        val r = cornerDp * dp
        canvas.clipPath(Path().apply {
            addRoundRect(RectF(0f, 0f, wf, hf), floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f), Path.Direction.CW)
        })

        val times = WidgetSky.sunTimes(date)
        val weights = WidgetSky.weights(minute, times)
        val stops = WidgetSky.skyStops(weights, dark)
        val night = weights[SkyPhase.NIGHT] ?: 0.0
        val dayness = weights[SkyPhase.DAY] ?: 0.0

        val band = (if (tier == WidgetTier.SMALL) 7f else 10f) * dp
        val horizonY = hf - band
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        // 1. Sky.
        paint.shader = LinearGradient(0f, 0f, 0f, horizonY, stops, floatArrayOf(0f, .62f, 1f), Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, wf, horizonY + 2 * dp, paint)
        paint.shader = null

        // Text sits in the top-left; bodies stay in the lower part of the sky.
        val textBand = when (tier) {
            WidgetTier.SMALL -> 26f
            WidgetTier.MEDIUM -> 44f
            WidgetTier.LARGE -> 50f
        } * dp
        val bodyR = (if (tier == WidgetTier.SMALL) 7f else 10f) * dp
        val arc = max(4 * dp, horizonY - textBand - bodyR - 2 * dp)

        // 2. Stars, only in the upper sky and only at night.
        if (night > .02) {
            val rng = Lcg(7)
            val star = if (dark) Color.WHITE else colors.primary
            val count = (wf / dp / 9).toInt().coerceIn(12, 40)
            for (i in 0 until count) {
                val x = rng.next() * wf
                val y = rng.next() * horizonY * .78
                val rad = ((if (dark) .6 else .75) + rng.next() * .9) * dp
                val a = (if (dark) .35 + rng.next() * .5 else .26 + rng.next() * .3) * night
                paint.color = withAlpha(star, a)
                canvas.drawCircle(x.toFloat(), y.toFloat(), rad.toFloat(), paint)
            }
        }

        val sunT = WidgetSky.sunArc(minute, times)
        val moonT = WidgetSky.moonArc(minute, times)
        val bodyX = { t: Double -> (wf * (.12 + .76 * t)).toFloat() }
        val bodyY = { t: Double, k: Float -> (horizonY + 2 * dp - sin(PI * t) * arc * k).toFloat() }

        // 3. Warm twilight glow on the horizon.
        val twilight = (1 - dayness - night).coerceIn(0.0, 1.0)
        if (twilight > .02) {
            val cx = sunT?.let(bodyX) ?: (wf / 2)
            val warm = lerp(rose, golden, if (minute < 720) .35 else .15)
            val strength = twilight * if (dark) .30 else .42
            val rx = wf * .85f
            canvas.save()
            canvas.translate(cx, horizonY)
            canvas.scale(1f, (horizonY * 1.15f) / (wf * 1.7f))
            paint.shader = RadialGradient(
                0f, 0f, rx,
                intArrayOf(withAlpha(warm, strength), withAlpha(warm, strength * .35), withAlpha(warm, 0.0)),
                floatArrayOf(0f, .45f, 1f), Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(0f, 0f, rx, paint)
            paint.shader = null
            canvas.restore()
        }

        // 4. A luminous band of air along the horizon, no outlines.
        val air = (1 - night * .7).coerceIn(0.0, 1.0)
        if (air > .02) {
            val top = horizonY - horizonY * .42f
            val haze = if (dark) withAlpha(0xFF9C95E8.toInt(), .07 * air) else withAlpha(Color.WHITE, .62 * air)
            paint.shader = LinearGradient(0f, top, 0f, horizonY, withAlpha(haze, 0.0), haze, Shader.TileMode.CLAMP)
            canvas.drawRect(0f, top, wf, horizonY + 2 * dp, paint)
            paint.shader = null
        }

        // 5. Sun or moon.
        if (sunT != null) {
            drawSun(canvas, bodyX(sunT), bodyY(sunT, 1f), bodyR, dayness, dark, dp)
        } else if (moonT != null) {
            drawMoon(canvas, bodyX(moonT), bodyY(moonT, .85f), bodyR, WidgetSky.moonPhase(date), colors, dp)
        }

        // 6. Ground: pale far ridge, sage band with a crisp line, then the page.
        val back = Path().apply {
            moveTo(0f, horizonY - 3 * dp)
            cubicTo(wf * .2f, horizonY - 9 * dp, wf * .36f, horizonY - 2 * dp, wf * .56f, horizonY - 6 * dp)
            cubicTo(wf * .76f, horizonY - 9 * dp, wf * .9f, horizonY - 4 * dp, wf, horizonY - 7 * dp)
            lineTo(wf, hf); lineTo(0f, hf); close()
        }
        paint.color = lerp(colors.groundBack, stops[2], .35)
        canvas.drawPath(back, paint)
        val ridge = Path().apply {
            moveTo(0f, horizonY + 2 * dp)
            cubicTo(wf * .2f, horizonY - 2 * dp, wf * .44f, horizonY + 3 * dp, wf * .68f, horizonY)
            cubicTo(wf * .84f, horizonY - 2 * dp, wf * .94f, horizonY + 1 * dp, wf, horizonY - 1 * dp)
        }
        val front = Path(ridge).apply { lineTo(wf, hf); lineTo(0f, hf); close() }
        paint.shader = LinearGradient(0f, horizonY - 3 * dp, 0f, hf, colors.groundTop, colors.groundBottom, Shader.TileMode.CLAMP)
        canvas.drawPath(front, paint)
        paint.shader = null
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * dp
            color = colors.groundLine
        }
        canvas.drawPath(ridge, stroke)
        // The page starts under the band with a short soft edge.
        val soft = 4f * dp
        paint.shader = LinearGradient(0f, hf - soft, 0f, hf, withAlpha(colors.surface, 0.0), colors.surface, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, hf - soft, wf, hf, paint)
        paint.shader = null

        // 7. Day path and dose capsules.
        if (marks.isNotEmpty()) {
            val inset = (if (tier == WidgetTier.SMALL) 18f else 24f) * dp
            val inner = max(1f, wf - 2 * inset)
            val baseY = horizonY - (if (tier == WidgetTier.SMALL) 9f else 13f) * dp
            val lift = min((if (tier == WidgetTier.SMALL) 4f else 9f) * dp, horizonY * .1f)
            val pathY = { x: Float ->
                val t = ((x - inset) / inner).coerceIn(0f, 1f)
                (baseY - sin(PI * t) * lift).toFloat()
            }
            val progress = (minute / 1440).coerceIn(0.0, 1.0).toFloat()
            val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(colors.ink, .30) }
            val dots = (inner / (6 * dp)).toInt().coerceAtLeast(1)
            for (i in 0..dots) {
                val t = i.toFloat() / dots
                if (t < progress) continue
                val x = inset + t * inner
                canvas.drawCircle(x, pathY(x), .95f * dp, dotPaint)
            }
            if (progress > 0f) {
                val behind = Path()
                val steps = 48
                val end = kotlin.math.ceil(progress * steps).toInt()
                for (i in 0..end) {
                    val x = inset + min(i.toFloat() / steps, progress) * inner
                    if (i == 0) behind.moveTo(x, pathY(x)) else behind.lineTo(x, pathY(x))
                }
                canvas.drawPath(behind, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeCap = Paint.Cap.ROUND
                    strokeWidth = 1.5f * dp
                    color = withAlpha(colors.primary, .5)
                })
            }

            val markScale = if (tier == WidgetTier.SMALL) .8f else 1f
            val step = 13f * dp * markScale
            val byMinute = marks.withIndex().groupBy { it.value.minute }
            val focus = WidgetSky.nextDueIndex(marks, minute)
            val placed = mutableListOf<Triple<Float, Float, IndexedValue<SkyMark>>>()
            for ((m, group) in byMinute.toSortedMap()) {
                val x0 = inset + m / 1440f * inner
                val shown = group.take(3)
                shown.forEachIndexed { i, mark ->
                    val x = x0 + (i - (shown.size - 1) / 2f) * step
                    placed += Triple(x, pathY(x), mark)
                }
            }
            placed.firstOrNull { it.third.index == focus }?.let { (x, y, _) ->
                val haloR = 15f * dp * markScale
                paint.shader = RadialGradient(
                    x, y, haloR,
                    withAlpha(colors.primary, if (dark) .38 else .24), withAlpha(colors.primary, 0.0),
                    Shader.TileMode.CLAMP,
                )
                canvas.drawCircle(x, y, haloR, paint)
                paint.shader = null
            }
            for ((x, y, mark) in placed) {
                drawCapsule(canvas, x, y, dp * markScale, mark.value.state, colors, null, mark.index == focus)
            }
            // A numeral above stacks of more than three.
            for ((m, group) in byMinute) {
                if (group.size <= 3) continue
                val x = inset + m / 1440f * inner
                val y = pathY(x) - 17f * dp * markScale
                val tp = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = colors.ink
                    textSize = 10f * dp
                    isFakeBoldText = true
                    textAlign = Paint.Align.CENTER
                }
                canvas.drawText("${group.size}", x, y, tp)
            }
        }
        return bmp
    }

    /**
     * One capsule at (cx, cy), [u] pixels per capsule unit (≈ dp). Shape
     * carries the state; the row text always repeats it in words.
     * TAKEN filled primary with a surface rim; DUE solid outline (half filled
     * with the medication colour in rows); MISSED a faded outline; SKIPPED a
     * muted outline with a seam; PRN a sage outline.
     */
    fun drawCapsule(
        canvas: Canvas,
        cx: Float,
        cy: Float,
        u: Float,
        state: CapsuleState,
        colors: WidgetColors,
        pillColor: Int?,
        focused: Boolean,
    ) {
        val rad = 6f * u
        val len = 19f * u
        val body = RectF(-rad, -len / 2, rad, len / 2)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.save()
        canvas.translate(cx, cy)
        canvas.rotate(MARK_TILT_DEG)
        if (focused) {
            p.style = Paint.Style.STROKE
            p.strokeWidth = 1.5f * u
            p.color = withAlpha(colors.ink, .75)
            val f = RectF(body).apply { inset(-3.5f * u, -3.5f * u) }
            canvas.drawRoundRect(f, rad + 3.5f * u, rad + 3.5f * u, p)
        }
        when (state) {
            CapsuleState.TAKEN -> {
                p.style = Paint.Style.FILL
                p.color = colors.surface
                val rim = RectF(body).apply { inset(-1.5f * u, -1.5f * u) }
                canvas.drawRoundRect(rim, rad + 1.5f * u, rad + 1.5f * u, p)
                p.color = colors.primary
                canvas.drawRoundRect(body, rad, rad, p)
                p.color = withAlpha(Color.WHITE, .4)
                p.strokeWidth = 1.6f * u
                p.strokeCap = Paint.Cap.ROUND
                p.style = Paint.Style.STROKE
                canvas.drawLine(-rad * .42f, -len / 2 + rad * .9f, -rad * .42f, -rad * .2f, p)
            }
            CapsuleState.SKIPPED -> {
                p.style = Paint.Style.FILL
                p.color = withAlpha(colors.surface, .8)
                canvas.drawRoundRect(body, rad, rad, p)
                p.style = Paint.Style.STROKE
                p.strokeWidth = 1.75f * u
                p.color = colors.inkMuted
                val inner = RectF(body).apply { inset(u, u) }
                canvas.drawRoundRect(inner, rad - u, rad - u, p)
                p.strokeCap = Paint.Cap.ROUND
                canvas.drawLine(-rad * .55f, 0f, rad * .55f, 0f, p)
            }
            CapsuleState.DUE, CapsuleState.MISSED, CapsuleState.PRN -> {
                val missed = state == CapsuleState.MISSED
                p.style = Paint.Style.FILL
                p.color = withAlpha(colors.surface, if (missed) .55 else .88)
                canvas.drawRoundRect(body, rad, rad, p)
                if (pillColor != null && !missed) {
                    canvas.save()
                    canvas.clipRect(-rad, 0f, rad, len / 2)
                    p.color = withAlpha(pillColor, .85)
                    canvas.drawRoundRect(body, rad, rad, p)
                    canvas.restore()
                }
                p.style = Paint.Style.STROKE
                p.strokeWidth = 2f * u
                p.color = when (state) {
                    CapsuleState.MISSED -> withAlpha(colors.inkMuted, .6)
                    CapsuleState.PRN -> colors.sage
                    else -> colors.ink
                }
                val inner = RectF(body).apply { inset(u, u) }
                canvas.drawRoundRect(inner, rad - u, rad - u, p)
            }
        }
        canvas.restore()
    }

    private fun drawSun(canvas: Canvas, x: Float, y: Float, r: Float, dayness: Double, dark: Boolean, dp: Float) {
        val warmth = (1 - dayness).coerceIn(0.0, 1.0)
        val color = if (dark) lerp(golden, rose, warmth) else lerp(paleSun, paleDawnSun, warmth)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        if (dark) {
            val halo = r * 4.2f
            p.shader = RadialGradient(
                x, y, halo,
                intArrayOf(withAlpha(color, .42), withAlpha(color, .16), withAlpha(color, 0.0)),
                floatArrayOf(0f, .35f, 1f), Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(x, y, halo, p)
        } else {
            val wide = r + 44 * dp
            p.shader = RadialGradient(
                x, y, wide,
                intArrayOf(withAlpha(color, .38), withAlpha(color, .13), withAlpha(color, 0.0)),
                floatArrayOf(0f, .4f, 1f), Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(x, y, wide, p)
            val halo = r + 18 * dp
            p.shader = RadialGradient(
                x, y, halo,
                intArrayOf(withAlpha(Color.WHITE, .7), withAlpha(Color.WHITE, .22), withAlpha(Color.WHITE, 0.0)),
                floatArrayOf(0f, .45f, 1f), Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(x, y, halo, p)
        }
        p.shader = RadialGradient(
            x - r * .22f, y - r * .28f, r * 1.25f,
            lerp(color, Color.WHITE, .5), color, Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(x, y, r, p)
    }

    private fun drawMoon(canvas: Canvas, x: Float, y: Float, r: Float, phase: Double, colors: WidgetColors, dp: Float) {
        val dark = colors.dark
        val lit = if (dark) 0xFFEDEBFF.toInt() else lerp(colors.primary, colors.surface, .06)
        val dim = if (dark) withAlpha(0xFFEDEBFF.toInt(), .12) else lerp(colors.primary, colors.surface, .68)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        val glow = if (dark) withAlpha(lit, .22) else withAlpha(Color.WHITE, .75)
        p.shader = RadialGradient(x, y, r * 3.4f, glow, withAlpha(glow, 0.0), Shader.TileMode.CLAMP)
        canvas.drawCircle(x, y, r * 3.4f, p)
        p.shader = null
        if (!dark) {
            p.color = colors.surface
            canvas.drawCircle(x, y, r + 1.5f * dp, p)
        }
        p.color = dim
        canvas.drawCircle(x, y, r, p)

        val k = cos(2 * PI * phase)
        val tw = (abs(k) * r).toFloat().coerceIn(.01f, r)
        val path = Path().apply {
            arcTo(RectF(-r, -r, r, r), -90f, 180f, true)
            arcTo(RectF(-tw, -r, tw, r), 90f, if (k > 0) -180f else 180f, false)
            close()
        }
        canvas.save()
        canvas.translate(x, y)
        if (phase >= .5) canvas.scale(-1f, 1f)
        p.color = withAlpha(lit, if (dark) .95 else .9)
        canvas.drawPath(path, p)
        canvas.restore()
    }

    fun withAlpha(color: Int, alpha: Double): Int = WidgetSky.withAlpha(color, alpha)

    fun lerp(a: Int, b: Int, t: Double): Int {
        fun ch(shift: Int): Int {
            val x = a shr shift and 0xFF
            val y = b shr shift and 0xFF
            return (x + (y - x) * t).toInt().coerceIn(0, 255)
        }
        return (ch(24) shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }

    private class Lcg(seed: Int) {
        private var state = seed.toLong()
        fun next(): Double {
            state = (state * 1103515245 + 12345) and 0x7fffffff
            return state / 2147483647.0
        }
    }
}
