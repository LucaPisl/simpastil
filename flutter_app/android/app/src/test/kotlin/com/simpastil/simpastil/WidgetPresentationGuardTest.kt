package com.simpastil.simpastil

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.TimeZone

class WidgetPresentationGuardTest {
    @Test
    fun `only explicit private boolean requests generic Open presentation`() {
        assertTrue(WidgetPresentationGuard.privatePresentation(mapOf("private" to true)))
        for (value in listOf(false, "true", 1, null)) {
            assertFalse(WidgetPresentationGuard.privatePresentation(mapOf("private" to value)))
        }
        assertFalse(WidgetPresentationGuard.privatePresentation(emptyMap()))
    }

    private val owner = "00000000-0000-4000-8000-000000000001"
    private val workspace = "00000000-0000-4000-8000-000000000020"
    private val occurrence = "00000000-0000-4000-8000-000000000002"
    private val identity = WidgetGrantIdentity(2, workspace, owner, 3L)
    private val marker = mapOf<String, Any?>(
        "version" to 2, "workspaceId" to workspace, "userId" to owner, "grantEpoch" to 3,
    )
    private val snapshot = mapOf<String, Any?>(
        "authenticated" to true, "projectionIdentity" to marker,
        "active_user_id" to owner, "session_generation" to 3,
    )

    private fun display(body: Map<String, Any?> = snapshot, stamp: Map<String, Any?>? = marker) =
        WidgetPresentationGuard.canDisplaySnapshot(body, stamp, owner, 3L)

    private fun scheduled(version: Long = 2L): Map<String, Any?> = marker + mapOf(
        "rowKind" to "scheduled", "stateVersion" to version, "status" to "pending",
        "active_user_id" to owner, "session_generation" to 3,
        "occurrenceId" to occurrence,
        "projectionId" to WidgetProjectionContract.widgetProjectionId(owner, 3, occurrence, workspace, 3L, version),
    )

    @Test
    fun `header needs the complete supported marker before showing care`() {
        assertTrue(display())
        assertFalse(display(stamp = null))
        assertFalse(display(stamp = marker + ("grantEpoch" to 4)))
        assertFalse(display(stamp = marker + ("workspaceId" to occurrence)))
        assertFalse(display(stamp = marker + ("version" to 3)))
        assertFalse(display(snapshot - "projectionIdentity"))
        assertFalse(display(snapshot + ("projectionIdentity" to (marker + ("userId" to occurrence)))))
        assertFalse(display(snapshot + ("active_user_id" to occurrence)))
        assertFalse(display(snapshot + ("session_generation" to 4)))
        assertFalse(WidgetPresentationGuard.canDisplaySnapshot(snapshot, marker, occurrence, 3L))
        assertFalse(WidgetPresentationGuard.canDisplaySnapshot(snapshot, marker, owner, 4L))
    }

    @Test
    fun `header refuses coerced authentication and numeric identity values`() {
        for (invalid in listOf(false, "true", 1, null)) {
            assertFalse(display(snapshot + ("authenticated" to invalid)))
        }
        for (invalid in listOf("3", 3.0, -1, null)) {
            assertFalse(display(snapshot + ("session_generation" to invalid)))
            assertNull(WidgetPresentationGuard.identity(marker + ("grantEpoch" to invalid)))
        }
        assertNull(WidgetPresentationGuard.identity(marker + ("version" to 2.0)))
    }

    @Test
    fun `every scheduled care label needs its full identity and delivered state version`() {
        val valid = scheduled()
        assertTrue(WidgetPresentationGuard.canDisplayRow(valid, identity))
        for (status in listOf("taken", "skipped", "missed")) {
            assertTrue(WidgetPresentationGuard.canDisplayRow((valid - "projectionId" - "occurrenceId") +
                ("status" to status), identity))
        }
        for (field in listOf("version", "workspaceId", "userId", "grantEpoch", "active_user_id",
            "session_generation", "stateVersion", "rowKind")) {
            assertFalse(field, WidgetPresentationGuard.canDisplayRow(valid - field, identity))
        }
        for (invalid in listOf(-1, "2", 2.0, null)) {
            assertFalse(WidgetPresentationGuard.canDisplayRow(valid + ("stateVersion" to invalid), identity))
        }
        assertFalse(WidgetPresentationGuard.canDisplayRow(valid + ("workspaceId" to occurrence), identity))
        assertFalse(WidgetPresentationGuard.canDisplayRow(valid + ("active_user_id" to occurrence), identity))
        assertFalse(WidgetPresentationGuard.canDisplayRow(valid + ("session_generation" to 4), identity))
        assertFalse(WidgetPresentationGuard.canDisplayRow(valid + ("isPrn" to "false"), identity))
        assertFalse(WidgetPresentationGuard.canDisplayRow(valid, identity.copy(grantEpoch = 4L)))
        assertFalse(WidgetPresentationGuard.canDisplayRow(valid, null))
    }

    @Test
    fun `pending buttons deliver the protected version and cannot use legacy or stale IDs`() {
        val valid = scheduled()
        val action = WidgetPresentationGuard.actionParameters(valid, identity)!!
        assertEquals("2", action["version"])
        assertEquals(workspace, action["workspaceId"])
        assertEquals("3", action["grantEpoch"])
        assertEquals("2", action["stateVersion"])
        assertEquals(8, action.size)
        assertNull(WidgetPresentationGuard.actionParameters(valid + ("stateVersion" to 4), identity))
        assertNull(WidgetPresentationGuard.actionParameters(valid + ("status" to "taken"), identity))
        assertNull(WidgetPresentationGuard.actionParameters(valid, identity.copy(grantEpoch = 4)))
        val legacy = valid - "version" - "workspaceId" - "userId" - "grantEpoch" - "stateVersion"
        assertNull(WidgetPresentationGuard.actionParameters(legacy + ("projectionId" to
            WidgetProjectionContract.widgetProjectionId(owner, 3, occurrence)), identity))
    }

    @Test
    fun `PRN summary displays under its grant but never offers a dose action`() {
        val prn = marker + mapOf("rowKind" to "prnSummary", "isPrn" to true, "status" to "pending",
            "active_user_id" to owner, "session_generation" to 3)
        assertTrue(WidgetPresentationGuard.canDisplayRow(prn, identity))
        assertNull(WidgetPresentationGuard.actionParameters(prn, identity))
        assertFalse(WidgetPresentationGuard.canDisplayRow(prn - "rowKind", identity))
        assertFalse(WidgetPresentationGuard.canDisplayRow(prn + ("isPrn" to false), identity))
        for (field in listOf("occurrenceId", "projectionId", "stateVersion")) {
            assertFalse(WidgetPresentationGuard.canDisplayRow(prn + (field to 0), identity))
        }
    }

    @Test
    fun `local care uses the same protected display contract`() {
        val localOwner = "local:$owner"
        val localIdentity = identity.copy(ownerId = localOwner)
        val localMarker = marker + ("userId" to localOwner)
        assertTrue(WidgetPresentationGuard.canDisplaySnapshot(snapshot + mapOf(
            "projectionIdentity" to localMarker, "active_user_id" to localOwner), localMarker, localOwner, 3L))
        val row = scheduled() + mapOf("userId" to localOwner, "active_user_id" to localOwner,
            "projectionId" to WidgetProjectionContract.widgetProjectionId(localOwner, 3, occurrence, workspace, 3L, 2L))
        assertTrue(WidgetPresentationGuard.canDisplayRow(row, localIdentity))
        assertEquals(localOwner, WidgetPresentationGuard.actionParameters(row, localIdentity)!!["active_user_id"])
    }
}

class WidgetSnapshotDayTest {
    @Test
    fun `only a snapshot from today is current`() {
        assertTrue(WidgetProjectionContract.snapshotIsCurrent("2026-10-16", "2026-10-16"))
        assertFalse(WidgetProjectionContract.snapshotIsCurrent("2026-10-15", "2026-10-16"))
        assertFalse(WidgetProjectionContract.snapshotIsCurrent(null, "2026-10-16"))
    }

    private fun nextRun(zone: String, local: String): ZonedDateTime {
        val id = ZoneId.of(zone)
        val now = java.time.LocalDateTime.parse(local).atZone(id).toInstant().toEpochMilli()
        val at = WidgetProjectionContract.nextMidnightUpdateMillis(now, TimeZone.getTimeZone(id))
        return java.time.Instant.ofEpochMilli(at).atZone(id)
    }

    private fun assertNextMidnight(zone: String, from: String, expectedDate: String) {
        val r = nextRun(zone, from)
        assertEquals(expectedDate, r.toLocalDate().toString())
        assertEquals(0, r.hour)
        assertEquals(1, r.minute)
        assertEquals(0, r.second)
    }

    @Test
    fun `midnight update on a normal day is 00 01 next day`() =
        assertNextMidnight("Europe/Bucharest", "2026-06-10T13:45:00", "2026-06-11")

    @Test
    fun `midnight update across DST spring forward is 00 01 local`() {
        // Bucharest 2026-03-29 03:00 -> 04:00; the day before schedules the shortened day.
        assertNextMidnight("Europe/Bucharest", "2026-03-28T22:00:00", "2026-03-29")
        assertNextMidnight("Europe/Bucharest", "2026-03-29T10:00:00", "2026-03-30")
    }

    @Test
    fun `midnight update across DST fall back is 00 01 local`() {
        // Bucharest 2026-10-25 04:00 -> 03:00; the day is 25 hours long.
        assertNextMidnight("Europe/Bucharest", "2026-10-24T22:00:00", "2026-10-25")
        assertNextMidnight("Europe/Bucharest", "2026-10-25T10:00:00", "2026-10-26")
    }
}
