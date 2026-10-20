package com.simpastil.simpastil

import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class ReportChannelExitReasonTest {
    @Test
    fun `an app update, a package state change and the freezer keep their own names`() {
        assertEquals(
            "package_updated",
            ReportChannel.exitReasonName(ApplicationExitInfo.REASON_PACKAGE_UPDATED),
        )
        assertEquals(
            "package_state_change",
            ReportChannel.exitReasonName(ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE),
        )
        assertEquals(
            "freezer",
            ReportChannel.exitReasonName(ApplicationExitInfo.REASON_FREEZER),
        )
    }

    @Test
    fun `existing reasons keep their names and anything else is other`() {
        assertEquals("crash", ReportChannel.exitReasonName(ApplicationExitInfo.REASON_CRASH))
        assertEquals(
            "user_requested",
            ReportChannel.exitReasonName(ApplicationExitInfo.REASON_USER_REQUESTED),
        )
        assertEquals("other", ReportChannel.exitReasonName(ApplicationExitInfo.REASON_OTHER))
        assertEquals("other", ReportChannel.exitReasonName(9999))
    }
}
