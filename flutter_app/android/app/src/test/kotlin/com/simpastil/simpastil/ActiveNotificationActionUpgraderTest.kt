package com.simpastil.simpastil

import org.junit.Assert.*
import org.junit.Test

class ActiveNotificationActionUpgraderTest {
    private val payload = "{\"version\":2,\"occurrenceId\":\"dose-1\",\"projectionId\":\"follow-up\",\"followUpMinutes\":30,\"workspaceId\":\"local\",\"grantEpoch\":4,\"stateVersion\":7}"
    private fun item(id: Any = 42, tag: Any? = null, raw: Any = payload,
                     actions: Any = listOf("taken", "snooze", "skip").map {
                         mapOf("id" to it, "cancelNotification" to (it != "snooze"))
                     }): Map<String, Any?> = mapOf("id" to id, "tag" to tag, "payload" to raw, "actions" to actions)
    private fun parse(vararg items: Map<String, Any?>) =
        ActiveNotificationActionEnvelope.parseBatch(mapOf("envelopes" to items.toList()))

    @Test fun forwardsOriginalPayloadAndExactPluginExtrasForEveryAction() {
        val envelope = parse(item(tag = "original-tag"))!!.single()
        assertEquals("SELECT_FOREGROUND_NOTIFICATION", ActiveNotificationActionEnvelope.FOREGROUND_ACTION)
        for ((index, action) in listOf("taken", "snooze", "skip").withIndex()) {
            assertEquals(mapOf("notificationId" to 42, "notificationTag" to "original-tag",
                "actionId" to action, "cancelNotification" to (action != "snooze"), "payload" to payload),
                envelope.extras(index))
        }
    }

    @Test fun rejectsMalformedOrDuplicateEnvelopeBeforeAnyReplacement() {
        assertNull(parse(item(id = "42")))
        assertNull(parse(item(id = -1)))
        assertNull(parse(item(raw = " ")))
        assertNull(parse(item(tag = 3)))
        assertNull(parse(item(), item()))
        assertNull(parse(item(actions = listOf(mapOf("id" to "open", "cancelNotification" to true)))))
        assertNull(parse(item(actions = listOf("skip", "snooze", "taken").map {
            mapOf("id" to it, "cancelNotification" to true)
        })))
        assertNull(parse(item() + ("unexpected" to true)))
    }

    @Test fun preservesPrivateAndForeignNotificationsByRefusingMismatchedActionsOrIdentity() {
        val envelope = parse(item())!!.single()
        val owner = "com.simpastil.simpastil"
        assertTrue(envelope.matches(42, null, owner, List(3) { owner }))
        assertFalse(envelope.matches(43, null, owner, List(3) { owner }))
        assertFalse(envelope.matches(42, "other-tag", owner, List(3) { owner }))
        assertFalse(envelope.matches(42, null, owner, listOf(owner))) // Open-only is untouched.
        assertFalse(envelope.matches(42, null, owner, listOf(owner, "foreign.app", owner)))
        assertFalse(envelope.matches(42, null, owner, listOf(owner, null, owner)))
    }
}
