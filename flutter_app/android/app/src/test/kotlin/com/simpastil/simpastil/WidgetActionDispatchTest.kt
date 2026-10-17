package com.simpastil.simpastil

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetActionDispatchTest {
    @Test
    fun `missing policy keeps the existing unlocked default`() {
        assertFalse(NativeAppLockPolicy.isEnabled(null, null))
    }

    @Test
    fun `legacy policy is honored only when it is a boolean`() {
        assertTrue(NativeAppLockPolicy.isEnabled(null, true))
        assertFalse(NativeAppLockPolicy.isEnabled(null, false))
        assertTrue(NativeAppLockPolicy.isEnabled(null, "true"))
    }

    @Test
    fun `versioned policy must have the exact supported shape`() {
        assertFalse(
            NativeAppLockPolicy.isEnabled(
                "{\"version\":1,\"enabled\":false,\"revision\":\"r1\"}",
                null,
            ),
        )
        assertTrue(
            NativeAppLockPolicy.isEnabled(
                "{\"version\":1,\"enabled\":true,\"revision\":\"r1\"}",
                false,
            ),
        )
        for (malformed in listOf(
            "{",
            "{\"version\":2,\"enabled\":false,\"revision\":\"r1\"}",
            "{\"version\":1,\"enabled\":false,\"revision\":\" \"}",
            "{\"version\":1,\"enabled\":false,\"revision\":\"r1\",\"extra\":true}",
            "{\"version\":1,\"enabled\":\"false\",\"revision\":\"r1\"}",
        )) {
            assertTrue(malformed, NativeAppLockPolicy.isEnabled(malformed, null))
        }
    }

    @Test
    fun `widget actions choose review when lock is enabled and headless otherwise`() {
        assertEquals(
            WidgetActionDestination.FOREGROUND_REVIEW,
            WidgetActionRouting.destination(lockEnabled = true),
        )
        assertEquals(
            WidgetActionDestination.HEADLESS,
            WidgetActionRouting.destination(lockEnabled = false),
        )
    }
}
