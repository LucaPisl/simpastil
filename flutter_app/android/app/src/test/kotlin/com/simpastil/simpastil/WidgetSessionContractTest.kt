package com.simpastil.simpastil

import java.io.InputStreamReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetSessionContractTest {
    @Test
    fun `preserves shared and additive preference keys from the cross runtime fixture`() {
        val fixture = javaClass.getResourceAsStream("/projection-command-ids-v1.json")
            ?.use { InputStreamReader(it).readText() }
            ?: error("Shared projection command fixture is missing")
        val keysSection = fixture.substringAfter("\"preferenceKeys\": {")
            .substringBefore("\n  }")
        val keys = Regex("\"([^\"]+)\"\\s*:\\s*\"([^\"]+)\"")
            .findAll(keysSection)
            .associate { it.groupValues[1] to it.groupValues[2] }

        assertEquals(keys.getValue("todayDoses"), WidgetProjectionContract.snapshotKey)
        assertEquals(keys.getValue("snapshotDay"), WidgetProjectionContract.snapshotDayKey)
        assertEquals(keys.getValue("appThemeMode"), WidgetProjectionContract.appThemeModeKey)
        assertEquals(keys.getValue("activeUserId"), WidgetProjectionContract.activeUserIdKey)
        assertEquals(keys.getValue("sessionGeneration"), WidgetProjectionContract.sessionGenerationKey)
        assertEquals("prn_in_stats_{userId}", keys.getValue("prnInStatsTemplate"))
        assertEquals("prn_in_widget_{userId}", keys.getValue("prnInWidgetTemplate"))
    }

    @Test
    fun `snapshot is renderable only for the persisted active owner and generation`() {
        assertTrue(
            WidgetProjectionContract.snapshotIdentityMatches(
                authenticated = true,
                snapshotOwner = "user-a",
                snapshotGeneration = 7L,
                activeOwner = "user-a",
                activeGeneration = 7L,
            ),
        )
        assertFalse(
            WidgetProjectionContract.snapshotIdentityMatches(
                authenticated = true,
                snapshotOwner = "user-a",
                snapshotGeneration = 7L,
                activeOwner = "user-b",
                activeGeneration = 8L,
            ),
        )
        assertFalse(
            WidgetProjectionContract.snapshotIdentityMatches(
                authenticated = false,
                snapshotOwner = "user-a",
                snapshotGeneration = 7L,
                activeOwner = "user-a",
                activeGeneration = 7L,
            ),
        )
    }

    @Test
    fun `native action payload requires matching occurrence projection and owner`() {
        val payload = WidgetProjectionContract.actionQueryParameters(
            action = "take",
            activeUserId = "00000000-0000-4000-8000-000000000001",
            sessionGeneration = 3,
            occurrenceId = "00000000-0000-4000-8000-000000000002",
            projectionId = WidgetProjectionContract.widgetProjectionId(
                "00000000-0000-4000-8000-000000000001",
                3,
                "00000000-0000-4000-8000-000000000002",
            ),
        )
        assertNotNull(payload)
        assertEquals(
            setOf("active_user_id", "session_generation", "occurrenceId", "projectionId"),
            payload!!.keys,
        )
        assertNull(
            WidgetProjectionContract.actionQueryParameters(
                action = "take",
                activeUserId = "00000000-0000-4000-8000-000000000001",
                sessionGeneration = 3,
                occurrenceId = "00000000-0000-4000-8000-000000000002",
                projectionId = "00000000-0000-4000-8000-000000000099",
            ),
        )
        assertNull(
            WidgetProjectionContract.actionQueryParameters(
                action = "take",
                activeUserId = null,
                sessionGeneration = 3,
                occurrenceId = "00000000-0000-4000-8000-000000000002",
                projectionId = "00000000-0000-4000-8000-000000000003",
            ),
        )
    }
}
