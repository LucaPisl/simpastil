package com.simpastil.simpastil

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import kotlin.math.cos
import kotlin.math.sin

/**
 * The nine pill silhouettes. The wire names are exactly the ones the Dart side
 * (`MedicationShape.wire`), the server and the sync payload use; never rename
 * one. `WidgetShapeContractTest` (Dart) and `WidgetMedicationLookTest`
 * (Kotlin) pin the list from both ends.
 */
internal enum class WidgetShape(val wire: String) {
    ROUND("round"),
    CAPLET("caplet"),
    OVAL("oval"),
    SOFTGEL("softgel"),
    CAPSULE("capsule"),
    TRIANGLE("triangle"),
    SQUARE("square"),
    DIAMOND("diamond"),
    DROP("drop");

    companion object {
        /** The shape named by [raw], or null when it is missing or unknown. */
        fun fromWire(raw: Any?): WidgetShape? = entries.firstOrNull { it.wire == raw }
    }
}

/** What a row draws a pill with: its silhouette and the letter(s) on it. */
internal data class WidgetLook(val shape: WidgetShape, val imprint: String)

internal object WidgetMedicationLook {
    /** Row field carrying the silhouette's wire name. */
    const val shapeField = WidgetProjectionContract.rowShapeField

    /** Row field carrying the one or two imprinted letters. */
    const val imprintField = WidgetProjectionContract.rowImprintField

    /** The widget row's mark is 30dp; the letter needs 22dp, two letters 28dp. */
    const val imprintMinDp = 22
    const val imprintTwoLetterMinDp = 28

    /**
     * The look a row asks for, or null when it carries none (a snapshot written
     * by an older app, or a name this build does not know), in which case the
     * row keeps drawing the widget's own capsule.
     */
    fun of(row: Map<String, Any?>): WidgetLook? {
        val shape = WidgetShape.fromWire(row[shapeField]) ?: return null
        return WidgetLook(shape, imprint(row[imprintField]))
    }

    /** At most the first two letters or digits of [raw]; empty when none. */
    fun imprint(raw: Any?): String {
        val text = raw as? String ?: return ""
        val out = StringBuilder()
        var taken = 0
        var i = 0
        while (i < text.length && taken < 2) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            if (Character.isLetterOrDigit(cp)) {
                out.appendCodePoint(cp)
                taken++
            }
        }
        return out.toString()
    }

    private fun channel(value: Int): Double {
        val c = value / 255.0
        return if (c <= 0.03928) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
    }

    fun luminance(argb: Int): Double =
        0.2126 * channel((argb shr 16) and 0xFF) +
            0.7152 * channel((argb shr 8) and 0xFF) +
            0.0722 * channel(argb and 0xFF)

    fun contrast(a: Int, b: Int): Double {
        val x = luminance(a) + .05
        val y = luminance(b) + .05
        return if (x > y) x / y else y / x
    }

    private fun mix(from: Int, to: Int, t: Double): Int {
        fun part(shift: Int): Int {
            val a = (from shr shift) and 0xFF
            val b = (to shr shift) and 0xFF
            return (a + (b - a) * t).toInt().coerceIn(0, 255)
        }
        return (0xFF shl 24) or (part(16) shl 16) or (part(8) shl 8) or part(0)
    }

    /**
     * The ink an imprint is pressed in on a pill of colour [base]: the tint
     * taken darker or lighter until it holds 3:1 against the pill, whichever
     * direction needs the smaller change. The same rule as the app's
     * `medicationImprintInk`.
     */
    fun ink(base: Int): Int {
        fun toward(target: Int): Int? {
            var t = .3
            while (t <= 1.0001) {
                val c = mix(base, target, t)
                if (contrast(c, base) >= 3) return c
                t += .05
            }
            return null
        }
        val dark = toward(0xFF000000.toInt())
        val light = toward(0xFFFFFFFF.toInt())
        if (dark != null && light != null) {
            return if (contrast(dark, base) <= contrast(light, base)) dark else light
        }
        return dark ?: light ?: 0xFF000000.toInt()
    }
}

/** Draws one pill, as the app's `MedicationMarkPainter` does, into a bitmap. */
internal object WidgetShapeBitmap {
    private const val GRID = 58f
    private const val TILT = -0.65f
    private const val SOFTGEL_TILT = -0.5f

    fun draw(
        px: Int,
        dp: Int,
        look: WidgetLook,
        fill: Int,
        stroke: Int,
        dashed: Boolean,
        letter: Int,
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val scale = px / GRID
        canvas.translate(px / 2f, px / 2f)
        canvas.scale(scale, scale)
        val path = silhouette(look.shape)
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = fill
        })
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.2f
            color = stroke
            if (dashed) pathEffect = DashPathEffect(floatArrayOf(4f, 3f), 0f)
        }
        canvas.drawPath(path, line)
        if (look.shape == WidgetShape.CAPSULE) {
            // The seam between the two halves.
            val seam = Path().apply { moveTo(-13f, 0f); lineTo(13f, 0f) }
            seam.transform(Matrix().apply { setRotate(Math.toDegrees(TILT.toDouble()).toFloat()) })
            canvas.drawPath(seam, line)
        }
        drawImprint(canvas, look, dp, letter)
        return bitmap
    }

    private fun rotated(path: Path, radians: Float): Path = path.apply {
        transform(Matrix().apply { setRotate(Math.toDegrees(radians.toDouble()).toFloat()) })
    }

    internal fun silhouette(shape: WidgetShape): Path = when (shape) {
        WidgetShape.ROUND -> Path().apply { addCircle(0f, 0f, 22f, Path.Direction.CW) }
        WidgetShape.CAPLET -> rotated(
            Path().apply { addRoundRect(RectF(-12f, -25f, 12f, 25f), 9f, 9f, Path.Direction.CW) },
            TILT,
        )
        WidgetShape.OVAL -> Path().apply { addOval(RectF(-26f, -17f, 26f, 17f), Path.Direction.CW) }
        WidgetShape.SOFTGEL -> rotated(
            Path().apply { addOval(RectF(-23f, -14f, 23f, 14f), Path.Direction.CW) },
            SOFTGEL_TILT,
        )
        WidgetShape.CAPSULE -> rotated(
            Path().apply { addRoundRect(RectF(-13f, -25f, 13f, 25f), 13f, 13f, Path.Direction.CW) },
            TILT,
        )
        WidgetShape.TRIANGLE -> roundedPolygon(
            listOf(0f to -25f, 24f to 18f, -24f to 18f), 5f,
        )
        WidgetShape.SQUARE -> Path().apply {
            addRoundRect(RectF(-20f, -20f, 20f, 20f), 8f, 8f, Path.Direction.CW)
        }
        WidgetShape.DIAMOND -> roundedPolygon(
            listOf(0f to -27f, 21f to 0f, 0f to 27f, -21f to 0f), 4f,
        )
        WidgetShape.DROP -> Path().apply {
            moveTo(0f, -25f)
            cubicTo(14f, -6f, 20f, 2f, 20f, 10f)
            arcTo(RectF(-20f, -10f, 20f, 30f), 0f, 180f, false)
            cubicTo(-20f, 2f, -14f, -6f, 0f, -25f)
            close()
        }
    }

    private fun roundedPolygon(corners: List<Pair<Float, Float>>, radius: Float): Path {
        val path = Path()
        val n = corners.size
        for (i in 0 until n) {
            val prev = corners[(i + n - 1) % n]
            val at = corners[i]
            val next = corners[(i + 1) % n]
            fun toward(other: Pair<Float, Float>): Pair<Float, Float> {
                val dx = other.first - at.first
                val dy = other.second - at.second
                val d = Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
                return (at.first + dx / d * radius) to (at.second + dy / d * radius)
            }
            val start = toward(prev)
            val end = toward(next)
            if (i == 0) path.moveTo(start.first, start.second) else path.lineTo(start.first, start.second)
            path.quadTo(at.first, at.second, end.first, end.second)
        }
        path.close()
        return path
    }

    private fun drawImprint(canvas: Canvas, look: WidgetLook, dp: Int, letter: Int) {
        var text = look.imprint
        if (text.isEmpty() || dp < WidgetMedicationLook.imprintMinDp) return
        if (text.codePointCount(0, text.length) > 1 && dp < WidgetMedicationLook.imprintTwoLetterMinDp) {
            text = text.substring(0, Character.charCount(text.codePointAt(0)))
        }
        val two = text.codePointCount(0, text.length) > 1
        // Where the letter sits and how large the pressed letter may be, per
        // silhouette: the same table as the app's painter.
        var at = 0f to 0f
        var fit = 1f
        when (look.shape) {
            WidgetShape.CAPLET -> fit = .8f
            WidgetShape.SOFTGEL -> { fit = .85f; at = 2f to 3f }
            WidgetShape.CAPSULE -> {
                fit = .7f
                at = (-sin(.65f) * 12.5f) to (-cos(.65f) * 12.5f)
            }
            WidgetShape.TRIANGLE -> { fit = .75f; at = 0f to 6f }
            WidgetShape.DIAMOND -> fit = .85f
            WidgetShape.DROP -> { fit = .85f; at = 0f to 9f }
            else -> {}
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = letter
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = (if (two) 17f else 23f) * fit
            textAlign = Paint.Align.CENTER
        }
        val metrics = paint.fontMetrics
        canvas.drawText(text, at.first, at.second - (metrics.ascent + metrics.descent) / 2f, paint)
    }
}
