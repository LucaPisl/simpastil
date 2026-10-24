package com.simpastil.simpastil

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetMedicationLookTest {
    @Test
    fun everyWireNameRoundTrips() {
        val names = listOf(
            "round", "caplet", "oval", "softgel", "capsule",
            "triangle", "square", "diamond", "drop",
        )
        assertEquals(names, WidgetShape.entries.map { it.wire })
        names.forEach { assertEquals(it, WidgetShape.fromWire(it)?.wire) }
    }

    @Test
    fun anOldPayloadWithoutShapeKeepsTheCapsule() {
        assertNull(WidgetMedicationLook.of(mapOf("pill" to "Aspirin", "color" to "#7C9885")))
    }

    @Test
    fun anUnknownShapeFallsBackToTheCapsule() {
        assertNull(WidgetMedicationLook.of(mapOf("shape" to "hexagon", "imprint" to "A")))
        assertNull(WidgetMedicationLook.of(mapOf("shape" to null)))
    }

    @Test
    fun aKnownShapeCarriesItsImprint() {
        val look = WidgetMedicationLook.of(mapOf("shape" to "drop", "imprint" to "Ab"))
        assertEquals(WidgetShape.DROP, look?.shape)
        assertEquals("Ab", look?.imprint)
    }

    @Test
    fun imprintKeepsAtMostTwoLettersOrDigits() {
        assertEquals("", WidgetMedicationLook.imprint(null))
        assertEquals("", WidgetMedicationLook.imprint("  -"))
        assertEquals("A", WidgetMedicationLook.imprint(" A"))
        assertEquals("Ab", WidgetMedicationLook.imprint("Abc"))
    }

    @Test
    fun inkHoldsThreeToOneOnEveryTint() {
        listOf(0xFFFFFFFF, 0xFF000000, 0xFF7C9885, 0xFFD0CFEC, 0xFF6E66FA, 0xFFE8B04A)
            .map { it.toInt() }
            .forEach { base ->
                val ink = WidgetMedicationLook.ink(base)
                assertTrue(WidgetMedicationLook.contrast(ink, base) >= 3.0)
            }
    }
}
