package com.simpastil.simpastil

import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Pure presentation model for the home-screen widget's day sky. It mirrors
 * the Flutter scene (lib/shared/scene/sun_table.dart and horizon_model.dart):
 * the same sun table, phase boundaries, palette keyframes and blend anchors,
 * so the widget and Today show the same light at the same minute.
 *
 * Nothing here touches Android APIs, so it runs in plain JVM unit tests
 * (WidgetSkyTest). It reads no preference keys: the caller passes values it
 * already read through WidgetProjectionContract.
 */
internal enum class SkyPhase { DAWN, DAY, DUSK, NIGHT }

/** Shape-first capsule states; words in the row always repeat the state. */
internal enum class CapsuleState { TAKEN, DUE, MISSED, SKIPPED, PRN }

/** Size tier chosen from the launcher-reported widget size in dp. */
internal enum class WidgetTier { SMALL, MEDIUM, LARGE }

internal data class SunTimes(val sunrise: Double, val sunset: Double) {
    val daylight: Double get() = sunset - sunrise
}

/** What the header says about the day. */
internal sealed class DaySummary {
    object NothingScheduled : DaySummary()
    object AllRecorded : DaySummary()
    data class Progress(val taken: Int, val total: Int) : DaySummary()
}

internal data class SkyMark(val minute: Int, val state: CapsuleState)

internal object WidgetSky {
    // Mid-month (day 15) sunrise/sunset in local minutes, about 45 N.
    // Keep in lockstep with SunTable._anchors in sun_table.dart.
    private val anchors = arrayOf(
        doubleArrayOf(465.0, 1025.0), doubleArrayOf(440.0, 1065.0),
        doubleArrayOf(390.0, 1095.0), doubleArrayOf(395.0, 1200.0),
        doubleArrayOf(350.0, 1235.0), doubleArrayOf(330.0, 1265.0),
        doubleArrayOf(350.0, 1260.0), doubleArrayOf(385.0, 1225.0),
        doubleArrayOf(425.0, 1175.0), doubleArrayOf(460.0, 1125.0),
        doubleArrayOf(410.0, 1015.0), doubleArrayOf(455.0, 1010.0),
    )

    fun sunTimes(date: LocalDate): SunTimes {
        val mid = date.withDayOfMonth(15)
        val before = date.isBefore(mid)
        val otherMid = mid.plusMonths(if (before) -1 else 1)
        val span = abs(ChronoUnit.DAYS.between(mid, otherMid)).toDouble()
        val t = abs(ChronoUnit.DAYS.between(mid, date)) / span
        val a = anchors[date.monthValue - 1]
        val b = anchors[otherMid.monthValue - 1]
        return SunTimes(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    }

    /** Same boundaries as HorizonModel._phaseAt. */
    fun phaseAt(minute: Double, t: SunTimes): SkyPhase = when {
        minute < t.sunrise - 45 || minute >= t.sunset + 50 -> SkyPhase.NIGHT
        minute < t.sunrise + 80 -> SkyPhase.DAWN
        minute < t.sunset - 70 -> SkyPhase.DAY
        else -> SkyPhase.DUSK
    }

    /** Blend weights of the four keyframes, as HorizonModel._weights. */
    fun weights(minute: Double, t: SunTimes): Map<SkyPhase, Double> {
        val keys = listOf(
            t.sunrise - 80 to SkyPhase.NIGHT,
            t.sunrise + 10 to SkyPhase.DAWN,
            t.sunrise + 130 to SkyPhase.DAY,
            t.sunset - 120 to SkyPhase.DAY,
            t.sunset - 5 to SkyPhase.DUSK,
            t.sunset + 85 to SkyPhase.NIGHT,
        )
        if (minute <= keys.first().first || minute >= keys.last().first) {
            return mapOf(SkyPhase.NIGHT to 1.0)
        }
        for (i in 0 until keys.size - 1) {
            val (am, ap) = keys[i]
            val (cm, cp) = keys[i + 1]
            if (minute in am..cm) {
                val u = (minute - am) / (cm - am)
                val s = u * u * (3 - 2 * u)
                val out = mutableMapOf<SkyPhase, Double>()
                out[ap] = (out[ap] ?: 0.0) + 1 - s
                out[cp] = (out[cp] ?: 0.0) + s
                return out
            }
        }
        return mapOf(SkyPhase.NIGHT to 1.0)
    }

    // Keyframes from HorizonModel._lightPalette / _darkPalette (top, mid, horizon).
    // Light stops keep luminance >= .8 and dark stops <= .03, so text needs no scrim.
    private val lightPalette = mapOf(
        SkyPhase.NIGHT to intArrayOf(0xFFE9E6FB.toInt(), 0xFFECE9FB.toInt(), 0xFFF2F0FD.toInt()),
        SkyPhase.DAWN to intArrayOf(0xFFF0E4FB.toInt(), 0xFFFBE6EE.toInt(), 0xFFFFE6CE.toInt()),
        SkyPhase.DAY to intArrayOf(0xFFE4EBFE.toInt(), 0xFFEEF2FF.toInt(), 0xFFF8F9FF.toInt()),
        SkyPhase.DUSK to intArrayOf(0xFFF0E4FB.toInt(), 0xFFFCE4EB.toInt(), 0xFFFFE5D0.toInt()),
    )
    private val darkPalette = mapOf(
        SkyPhase.NIGHT to intArrayOf(0xFF0A0A16.toInt(), 0xFF120F2E.toInt(), 0xFF1E1840.toInt()),
        SkyPhase.DAWN to intArrayOf(0xFF1A1250.toInt(), 0xFF2A2152.toInt(), 0xFF3E2842.toInt()),
        SkyPhase.DAY to intArrayOf(0xFF0F1438.toInt(), 0xFF1A2050.toInt(), 0xFF202A5C.toInt()),
        SkyPhase.DUSK to intArrayOf(0xFF160F34.toInt(), 0xFF2C1B48.toInt(), 0xFF3E2842.toInt()),
    )

    fun keyframe(phase: SkyPhase, dark: Boolean): IntArray =
        (if (dark) darkPalette else lightPalette).getValue(phase).copyOf()

    /** Three opaque ARGB stops: top, 62 %, horizon. */
    fun skyStops(weights: Map<SkyPhase, Double>, dark: Boolean): IntArray {
        val palette = if (dark) darkPalette else lightPalette
        return IntArray(3) { i ->
            var r = 0.0
            var g = 0.0
            var b = 0.0
            for ((phase, w) in weights) {
                val c = palette.getValue(phase)[i]
                r += (c shr 16 and 0xFF) * w
                g += (c shr 8 and 0xFF) * w
                b += (c and 0xFF) * w
            }
            (0xFF shl 24) or (channel(r) shl 16) or (channel(g) shl 8) or channel(b)
        }
    }

    private fun channel(v: Double): Int = v.roundToInt().coerceIn(0, 255)

    fun withAlpha(color: Int, alpha: Double): Int {
        val a = ((color ushr 24) * alpha.coerceIn(0.0, 1.0)).toInt()
        return (a shl 24) or (color and 0x00FFFFFF)
    }

    /** WCAG contrast ratio between two opaque colours. */
    fun contrast(a: Int, b: Int): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (maxOf(la, lb) + .05) / (minOf(la, lb) + .05)
    }

    /** WCAG relative luminance of an opaque ARGB colour. */
    fun luminance(argb: Int): Double {
        fun lin(c: Int): Double {
            val s = c / 255.0
            return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(argb shr 16 and 0xFF) + 0.7152 * lin(argb shr 8 and 0xFF) +
            0.0722 * lin(argb and 0xFF)
    }

    /** Position of the sun along its arc, or null when it is below the horizon. */
    fun sunArc(minute: Double, t: SunTimes): Double? {
        val u = (minute - t.sunrise) / t.daylight
        return u.takeIf { it > -.06 && it < 1.06 }
    }

    /** Position of the moon along the night arc, or null while the sun is up. */
    fun moonArc(minute: Double, t: SunTimes): Double? {
        if (sunArc(minute, t) != null) return null
        val night = 1440 - t.daylight
        val since = if (minute >= t.sunset) minute - t.sunset else minute + 1440 - t.sunset
        return (since / night).takeIf { it > -.02 && it < 1.02 }
    }

    /** Synodic moon phase, 0 new .. 0.5 full .. 1 (HorizonModel.moonPhaseOf). */
    fun moonPhase(date: LocalDate): Double {
        val jd = date.toEpochDay() + 0.5 + 2440587.5
        val p = ((jd - 2451550.1) / 29.530588853) % 1
        return if (p < 0) p + 1 else p
    }

    /**
     * Row status to capsule state. Unknown statuses fall back to DUE, which
     * draws an outline with no action of its own: the Take wiring stays in
     * WidgetPresentationGuard.actionParameters.
     */
    fun capsuleState(status: String?, isPrn: Boolean): CapsuleState = when {
        isPrn -> CapsuleState.PRN
        status == "taken" -> CapsuleState.TAKEN
        status == "missed" -> CapsuleState.MISSED
        status == "skipped" -> CapsuleState.SKIPPED
        else -> CapsuleState.DUE
    }

    /** "HH:MM" to minutes after midnight; anything else is null. */
    fun minuteOf(time: String?): Int? {
        if (time == null || time.length < 5 || time[2] != ':') return null
        val h = time.substring(0, 2).toIntOrNull() ?: return null
        val m = time.substring(3, 5).toIntOrNull() ?: return null
        return if (h in 0..23 && m in 0..59) h * 60 + m else null
    }

    /**
     * A row's "HH:MM" on the phone's clock, through [pattern] (the platform's
     * best pattern for "Hm" on a 24-hour phone, else for "jm", the language's
     * own clock, as the app does). Anything else, such as an as-needed
     * row's count, is shown as written.
     */
    fun clockLabel(time: String?, pattern: String, locale: Locale): String {
        val minute = minuteOf(time) ?: return time.orEmpty()
        return runCatching {
            DateTimeFormatter.ofPattern(pattern, locale)
                .format(LocalTime.of(minute / 60, minute % 60))
        }.getOrDefault(time.orEmpty())
    }

    /**
     * Header text. Recorded means taken or skipped (as the Today sky's
     * "settled"); a missed dose is never called recorded.
     */
    fun summarize(taken: Int, total: Int, scheduledStatuses: List<String?>): DaySummary = when {
        total <= 0 -> DaySummary.NothingScheduled
        scheduledStatuses.size >= total &&
            scheduledStatuses.all { it == "taken" || it == "skipped" } -> DaySummary.AllRecorded
        else -> DaySummary.Progress(taken.coerceIn(0, total), total)
    }

    /** The next due mark at or after [minute], else the last due one. */
    fun nextDueIndex(marks: List<SkyMark>, minute: Double): Int? {
        val due = marks.withIndex().filter { it.value.state == CapsuleState.DUE }
        if (due.isEmpty()) return null
        return (due.firstOrNull { it.value.minute >= minute } ?: due.last()).index
    }

    /**
     * Height thresholds in dp: about 2 cells (110 dp) is SMALL, 3 cells
     * MEDIUM, 4+ cells LARGE. Unknown (0) sizes use MEDIUM.
     */
    fun tier(heightDp: Int): WidgetTier = when {
        heightDp <= 0 -> WidgetTier.MEDIUM
        heightDp < 150 -> WidgetTier.SMALL
        heightDp < 250 -> WidgetTier.MEDIUM
        else -> WidgetTier.LARGE
    }

    /** Sky header height in dp for a tier; an empty day lets the sky breathe. */
    fun skyHeightDp(tier: WidgetTier, empty: Boolean): Int = when (tier) {
        WidgetTier.SMALL -> if (empty) 70 else 58
        WidgetTier.MEDIUM -> if (empty) 112 else 94
        WidgetTier.LARGE -> if (empty) 150 else 118
    }
}

/** Colours for one brightness. Brand palette: #6E66FA, white, #141414, #7C9885, #D0CFEC. */
internal class WidgetColors(val dark: Boolean) {
    val surface = if (dark) 0xFF141414.toInt() else 0xFFFFFFFF.toInt()
    val ink = if (dark) 0xFFFFFFFF.toInt() else 0xFF141414.toInt()
    val inkMuted = if (dark) 0xFFD0CFEC.toInt() else 0xFF4A4858.toInt()
    val primary = if (dark) 0xFFB3AEFC.toInt() else 0xFF6E66FA.toInt()
    val onPrimary = if (dark) 0xFF141414.toInt() else 0xFFFFFFFF.toInt()
    val lavender = 0xFFD0CFEC.toInt()
    val sage = if (dark) 0xFFA9C2B0.toInt() else 0xFF56705E.toInt()

    // Ground colours as HorizonPalette.from derives them from the sage tertiary.
    val groundTop = sageTone(if (dark) .17 else .88, if (dark) .2 else .22)
    val groundBottom = sageTone(if (dark) .15 else .86, if (dark) .2 else .22)
    val groundBack = sageTone(if (dark) .14 else .9, .16)
    val groundLine = sageTone(if (dark) .3 else .72, .2)

    companion object {
        private const val SAGE_HUE = 139.3 // hue of #7C9885

        fun sageTone(lightness: Double, saturation: Double): Int {
            val c = (1 - abs(2 * lightness - 1)) * saturation
            val hp = SAGE_HUE / 60
            val x = c * (1 - abs(hp % 2 - 1))
            val (r1, g1, b1) = when (hp.toInt()) {
                0 -> Triple(c, x, 0.0)
                1 -> Triple(x, c, 0.0)
                2 -> Triple(0.0, c, x)
                3 -> Triple(0.0, x, c)
                4 -> Triple(x, 0.0, c)
                else -> Triple(c, 0.0, x)
            }
            val m = lightness - c / 2
            fun ch(v: Double) = ((v + m) * 255).toInt().coerceIn(0, 255)
            return (0xFF shl 24) or (ch(r1) shl 16) or (ch(g1) shl 8) or ch(b1)
        }
    }
}


internal enum class CapsuleStroke { RIM, OUTLINE, SKIPPED }

/** Tints for the three row capsule layers (fill, medication half, stroke). */
internal data class CapsuleLayers(val fill: Int, val half: Int?, val shape: CapsuleStroke, val stroke: Int)

internal object WidgetCapsuleLayers {
    fun forState(state: CapsuleState, colors: WidgetColors, medication: Int): CapsuleLayers = when (state) {
        CapsuleState.TAKEN -> CapsuleLayers(colors.primary, null, CapsuleStroke.RIM, colors.surface)
        CapsuleState.DUE -> CapsuleLayers(colors.surface, medication, CapsuleStroke.OUTLINE, colors.ink)
        CapsuleState.MISSED -> CapsuleLayers(
            colors.surface, null, CapsuleStroke.OUTLINE, WidgetSky.withAlpha(colors.inkMuted, .6),
        )
        CapsuleState.SKIPPED -> CapsuleLayers(colors.surface, null, CapsuleStroke.SKIPPED, colors.inkMuted)
        CapsuleState.PRN -> CapsuleLayers(colors.surface, medication, CapsuleStroke.OUTLINE, colors.sage)
    }
}
