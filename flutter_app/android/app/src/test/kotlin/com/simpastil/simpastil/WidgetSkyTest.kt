package com.simpastil.simpastil

import java.time.LocalDate
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetSkyTest {
    private val october12 = LocalDate.of(2026, 10, 12)

    @Test
    fun `sun table matches the Flutter mid-month anchors`() {
        val june = WidgetSky.sunTimes(LocalDate.of(2026, 6, 15))
        assertEquals(330.0, june.sunrise, 1e-9)
        assertEquals(1265.0, june.sunset, 1e-9)
        // Oct 12 interpolates between Sep 15 and Oct 15: 3/30 of the way back.
        val oct = WidgetSky.sunTimes(october12)
        assertEquals(460 + (425 - 460) * 3 / 30.0, oct.sunrise, 1e-9)
        assertEquals(1125 + (1175 - 1125) * 3 / 30.0, oct.sunset, 1e-9)
    }

    @Test
    fun `phase boundaries mirror HorizonModel phaseAt`() {
        val t = SunTimes(sunrise = 400.0, sunset = 1100.0)
        assertEquals(SkyPhase.NIGHT, WidgetSky.phaseAt(354.9, t))
        assertEquals(SkyPhase.DAWN, WidgetSky.phaseAt(355.0, t))
        assertEquals(SkyPhase.DAWN, WidgetSky.phaseAt(479.9, t))
        assertEquals(SkyPhase.DAY, WidgetSky.phaseAt(480.0, t))
        assertEquals(SkyPhase.DAY, WidgetSky.phaseAt(1029.9, t))
        assertEquals(SkyPhase.DUSK, WidgetSky.phaseAt(1030.0, t))
        assertEquals(SkyPhase.DUSK, WidgetSky.phaseAt(1149.9, t))
        assertEquals(SkyPhase.NIGHT, WidgetSky.phaseAt(1150.0, t))
        assertEquals(SkyPhase.NIGHT, WidgetSky.phaseAt(0.0, t))
    }

    @Test
    fun `scene clock times land in the same phases as the Flutter tests`() {
        val t = WidgetSky.sunTimes(october12)
        assertEquals(SkyPhase.DAWN, WidgetSky.phaseAt(6 * 60.0 + 59, t))
        assertEquals(SkyPhase.DAY, WidgetSky.phaseAt(12 * 60.0, t))
        assertEquals(SkyPhase.DUSK, WidgetSky.phaseAt(18 * 60.0 + 50, t))
        assertEquals(SkyPhase.NIGHT, WidgetSky.phaseAt(23 * 60.0, t))
    }

    @Test
    fun `blend weights sum to one and are pure night outside the anchors`() {
        val t = SunTimes(400.0, 1100.0)
        for (m in 0 until 1440 step 7) {
            val sum = WidgetSky.weights(m.toDouble(), t).values.sum()
            assertEquals("minute $m", 1.0, sum, 1e-9)
        }
        assertEquals(mapOf(SkyPhase.NIGHT to 1.0), WidgetSky.weights(100.0, t))
        assertEquals(mapOf(SkyPhase.DAY to 1.0), WidgetSky.weights(800.0, t).filterValues { it > 0 })
    }

    @Test
    fun `light skies stay light and dark skies stay dark at every minute`() {
        val t = WidgetSky.sunTimes(october12)
        for (m in 0 until 1440 step 5) {
            val w = WidgetSky.weights(m.toDouble(), t)
            WidgetSky.skyStops(w, dark = false).forEach {
                assertTrue("light $m ${Integer.toHexString(it)}", WidgetSky.luminance(it) >= .8)
            }
            WidgetSky.skyStops(w, dark = true).forEach {
                assertTrue("dark $m ${Integer.toHexString(it)}", WidgetSky.luminance(it) <= .03)
            }
        }
    }

    @Test
    fun `pure keyframe weights reproduce the palette`() {
        for (phase in SkyPhase.values()) {
            for (dark in listOf(false, true)) {
                val stops = WidgetSky.skyStops(mapOf(phase to 1.0), dark)
                assertEquals(WidgetSky.keyframe(phase, dark).toList(), stops.toList())
            }
        }
    }

    @Test
    fun `sun is up by day and the moon takes over at night`() {
        val t = SunTimes(400.0, 1100.0)
        assertNotNull(WidgetSky.sunArc(750.0, t))
        assertNull(WidgetSky.moonArc(750.0, t))
        assertNull(WidgetSky.sunArc(1300.0, t))
        assertNotNull(WidgetSky.moonArc(1300.0, t))
        assertNotNull(WidgetSky.moonArc(100.0, t))
        assertEquals(.5, WidgetSky.sunArc(750.0, t)!!, 1e-9)
    }

    @Test
    fun `row status maps to capsule state`() {
        assertEquals(CapsuleState.TAKEN, WidgetSky.capsuleState("taken", false))
        assertEquals(CapsuleState.MISSED, WidgetSky.capsuleState("missed", false))
        assertEquals(CapsuleState.SKIPPED, WidgetSky.capsuleState("skipped", false))
        assertEquals(CapsuleState.DUE, WidgetSky.capsuleState("pending", false))
        assertEquals(CapsuleState.DUE, WidgetSky.capsuleState(null, false))
        assertEquals(CapsuleState.DUE, WidgetSky.capsuleState("unknown", false))
        assertEquals(CapsuleState.PRN, WidgetSky.capsuleState("taken", true))
    }

    @Test
    fun `summary reports missed and empty days`() {
        assertEquals(DaySummary.NothingScheduled, WidgetSky.summarize(0, 0, emptyList()))
        assertEquals(DaySummary.AllRecorded, WidgetSky.summarize(2, 2, listOf("taken", "taken")))
        assertEquals(DaySummary.AllRecorded, WidgetSky.summarize(1, 2, listOf("taken", "skipped")))
        assertEquals(DaySummary.Progress(1, 2), WidgetSky.summarize(1, 2, listOf("taken", "missed")))
        assertEquals(DaySummary.Progress(1, 2), WidgetSky.summarize(1, 2, listOf("taken", "pending")))
        // Rows hidden by the guard never turn a partial day into "All recorded".
        assertEquals(DaySummary.Progress(1, 3), WidgetSky.summarize(1, 3, listOf("taken")))
    }

    @Test
    fun `time parsing accepts HH colon MM only`() {
        assertEquals(8 * 60, WidgetSky.minuteOf("08:00"))
        assertEquals(23 * 60 + 59, WidgetSky.minuteOf("23:59"))
        assertNull(WidgetSky.minuteOf("2× today"))
        assertNull(WidgetSky.minuteOf("24:00"))
        assertNull(WidgetSky.minuteOf(""))
        assertNull(WidgetSky.minuteOf(null))
    }

    @Test
    fun `row times follow the phone's clock and leave other words alone`() {
        assertEquals("20:05", WidgetSky.clockLabel("20:05", "HH:mm", Locale.US))
        assertEquals("8:05 PM", WidgetSky.clockLabel("20:05", "h:mm a", Locale.US))
        assertEquals("12:00 AM", WidgetSky.clockLabel("00:00", "h:mm a", Locale.US))
        assertEquals("2× today", WidgetSky.clockLabel("2× today", "h:mm a", Locale.US))
        assertEquals("", WidgetSky.clockLabel(null, "HH:mm", Locale.US))
        assertEquals("08:00", WidgetSky.clockLabel("08:00", "not a [pattern", Locale.US))
    }

    @Test
    fun `next due mark is the first pending one from now`() {
        val marks = listOf(
            SkyMark(480, CapsuleState.TAKEN),
            SkyMark(780, CapsuleState.DUE),
            SkyMark(1200, CapsuleState.DUE),
        )
        assertEquals(1, WidgetSky.nextDueIndex(marks, 600.0))
        assertEquals(2, WidgetSky.nextDueIndex(marks, 900.0))
        assertEquals(2, WidgetSky.nextDueIndex(marks, 1300.0))
        assertNull(WidgetSky.nextDueIndex(marks.take(1), 600.0))
    }

    @Test
    fun `size tiers follow cell heights`() {
        assertEquals(WidgetTier.MEDIUM, WidgetSky.tier(0))
        assertEquals(WidgetTier.SMALL, WidgetSky.tier(110))
        assertEquals(WidgetTier.MEDIUM, WidgetSky.tier(180))
        assertEquals(WidgetTier.LARGE, WidgetSky.tier(320))
        for (tier in WidgetTier.values()) {
            assertTrue(WidgetSky.skyHeightDp(tier, empty = true) > WidgetSky.skyHeightDp(tier, empty = false))
        }
    }

    @Test
    fun `header text reads at 7 to 1 on every sky stop`() {
        val t = WidgetSky.sunTimes(october12)
        for (dark in listOf(false, true)) {
            val ink = WidgetColors(dark).ink
            for (m in 0 until 1440 step 10) {
                WidgetSky.skyStops(WidgetSky.weights(m.toDouble(), t), dark).forEach {
                    assertTrue("dark=$dark minute $m", WidgetSky.contrast(ink, it) >= 7.0)
                }
            }
        }
    }

    @Test
    fun `capsule layers keep taken filled and missed distinct`() {
        for (dark in listOf(false, true)) {
            val c = WidgetColors(dark)
            val med = 0xFFE91E63.toInt()
            val taken = WidgetCapsuleLayers.forState(CapsuleState.TAKEN, c, med)
            assertEquals(c.primary, taken.fill)
            assertEquals(CapsuleStroke.RIM, taken.shape)
            assertNull(taken.half)
            val due = WidgetCapsuleLayers.forState(CapsuleState.DUE, c, med)
            assertEquals(med, due.half)
            assertEquals(CapsuleStroke.OUTLINE, due.shape)
            assertTrue(WidgetSky.contrast(due.stroke, c.surface) >= 3.0)
            // Missed never borrows the medication colour or the taken fill.
            val missed = WidgetCapsuleLayers.forState(CapsuleState.MISSED, c, med)
            assertNull(missed.half)
            assertEquals(c.surface, missed.fill)
            assertEquals(CapsuleStroke.SKIPPED, WidgetCapsuleLayers.forState(CapsuleState.SKIPPED, c, med).shape)
            assertTrue(WidgetSky.contrast(c.primary, c.surface) >= 3.0)
        }
    }
}
