package com.simpastil.simpastil

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectedWidgetContractTest {
    @Test
    fun `Dart and Kotlin share connected and local delivered version vectors`() {
        val fixture = javaClass.getResourceAsStream("/projection-command-ids-v2.json")
            ?.bufferedReader()?.use { it.readText() } ?: error("Missing v2 fixture")
        val stringField = Regex("\"([^\"]+)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"")
        val numberField = Regex("\"([^\"]+)\"\\s*:\\s*(\\d+)")
        val vectors = Regex("""\{([^{}]*)\}""").findAll(fixture).filter {
            it.groupValues[1].contains("\"canonicalKey\"")
        }.toList()
        assertEquals(4, vectors.size)
        for (vector in vectors) {
            val strings = stringField.findAll(vector.groupValues[1]).associate {
                it.groupValues[1] to it.groupValues[2].replace("\\\"", "\"")
            }
            val numbers = numberField.findAll(vector.groupValues[1]).associate {
                it.groupValues[1] to it.groupValues[2].toLong()
            }
            val owner = strings.getValue("userId")
            val workspace = strings.getValue("workspaceId")
            val epoch = numbers.getValue("grantEpoch")
            val version = numbers.getValue("stateVersion")
            val occurrence = strings.getValue("occurrenceId")
            val projection = WidgetProjectionContract.widgetProjectionId(owner, epoch.toInt(), occurrence,
                workspace, epoch, version)
            assertEquals(strings.getValue("projectionId"), projection)
            assertEquals(strings.getValue("canonicalKey"), WidgetProjectionContract.widgetProjectionCanonicalKey(
                owner, epoch.toInt(), occurrence, workspace, epoch, version))
            for (action in listOf("take", "skip")) {
                assertEquals(strings.getValue("${action}CommandId"), WidgetProjectionContract.widgetActionCommandId(
                    projection, occurrence, action))
                val parameters = WidgetProjectionContract.actionQueryParameters(action, owner, epoch.toInt(), occurrence,
                    projection, workspace, epoch, version)!!
                assertEquals(setOf("version", "workspaceId", "grantEpoch", "stateVersion", "active_user_id",
                    "session_generation", "occurrenceId", "projectionId"), parameters.keys)
                assertEquals(version.toString(), parameters.getValue("stateVersion"))
                assertNull(WidgetProjectionContract.actionQueryParameters(action, owner, epoch.toInt(), occurrence,
                    projection, workspace, epoch, version + 1))
                assertNull(WidgetProjectionContract.actionQueryParameters(action, owner, epoch.toInt(), occurrence,
                    projection, workspace, epoch, null))
            }
        }
        assertTrue(fixture.contains(WidgetProjectionContract.projectionIdentityKey))
        assertTrue(fixture.contains(WidgetProjectionContract.retirementIntentKey))
    }

    @Test
    fun `native display requires identical full supported marker and snapshot identity`() {
        val owner = "local:00000000-0000-4000-8000-000000000001"
        val identity = WidgetGrantIdentity(2, "00000000-0000-4000-8000-000000000020", owner, 3L)
        fun matches(marker: WidgetGrantIdentity?) = WidgetProjectionContract.protectedSnapshotIdentityMatches(
            identity, marker, owner, 3L, owner, 3L)
        assertTrue(matches(identity))
        assertFalse(matches(null))
        assertFalse(matches(identity.copy(grantEpoch = 4L)))
        assertFalse(matches(identity.copy(workspaceId = "00000000-0000-4000-8000-000000000021")))
        assertFalse(matches(identity.copy(version = 3)))
        assertFalse(WidgetProjectionContract.protectedSnapshotIdentityMatches(
            identity, identity, owner, 3L, "00000000-0000-4000-8000-000000000001", 3L))
        assertFalse(WidgetProjectionContract.validIdentity(identity.copy(ownerId = "unbound")))
    }
}
