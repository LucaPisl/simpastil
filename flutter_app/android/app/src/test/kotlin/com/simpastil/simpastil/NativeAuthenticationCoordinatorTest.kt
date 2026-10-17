package com.simpastil.simpastil

import org.junit.Assert.*
import org.junit.Test

class NativeAuthenticationCoordinatorTest {
    @Test fun requiresNonblankLocalizedFallbackLabel() {
        val coordinator = NativeAuthenticationCoordinator()
        coordinator.resume()
        assertNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock")))
        assertNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to 7)))
        assertNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to " ")))
        val request = coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Folosește blocarea dispozitivului"))!!
        assertEquals("Folosește blocarea dispozitivului", request.fallbackLabel)
    }

    @Test fun rejectsMalformedBusyAndNonforegroundAttempts() {
        val coordinator = NativeAuthenticationCoordinator()
        assertNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock")))
        coordinator.resume()
        assertNull(coordinator.begin(mapOf("attemptId" to "", "reason" to "Unlock", "fallbackLabel" to "Use device lock")))
        assertNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to 1, "fallbackLabel" to "Use device lock")))
        assertNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock", "extra" to true)))
        assertNotNull(coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock")))
        assertNull(coordinator.begin(mapOf("attemptId" to "two", "reason" to "Unlock", "fallbackLabel" to "Use device lock")))
    }

    @Test fun oldSuccessCannotCompleteANewerAttemptAndResultsCompleteOnce() {
        val coordinator = NativeAuthenticationCoordinator()
        coordinator.resume()
        val old = coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock"))!!
        assertSame(old, coordinator.invalidate())
        assertEquals(false, coordinator.context()["foreground"])
        coordinator.resume()
        val current = coordinator.begin(mapOf("attemptId" to "two", "reason" to "Unlock", "fallbackLabel" to "Use device lock"))!!
        assertNull(coordinator.complete(old, true))
        assertEquals(mapOf("attemptId" to "two", "authenticated" to true), coordinator.complete(current, true))
        assertNull(coordinator.complete(current, true))
    }

    @Test fun onlyOneExplicitCredentialPausePreservesAttemptGeneration() {
        val coordinator = NativeAuthenticationCoordinator()
        coordinator.resume()
        val request = coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock"))!!
        coordinator.prepareCredential(request, "challenge")!!
        assertTrue(coordinator.pause())
        assertEquals(0L, coordinator.leaveGeneration)
        assertEquals("one", coordinator.resume())
        assertFalse(coordinator.pause())
        assertEquals(1L, coordinator.leaveGeneration)
        assertFalse(coordinator.isCurrent(request))
    }

    @Test fun resultBeforeResumeIsHeldOnlyForExactChallengeAndRecheckedAfterInvalidation() {
        val coordinator = NativeAuthenticationCoordinator()
        coordinator.resume()
        val request = coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock"))!!
        val challenge = coordinator.prepareCredential(request, "challenge")!!
        coordinator.pause()
        assertEquals(CredentialChallengeResultDisposition.REJECTED,
            coordinator.credentialResult(challenge.requestCode + 1, true))
        assertEquals(CredentialChallengeResultDisposition.HOLD_FOR_RESUME,
            coordinator.credentialResult(challenge.requestCode, true))
        assertFalse(coordinator.acceptHeldCredential())
        assertEquals("one", coordinator.resume())
        assertTrue(coordinator.acceptHeldCredential())
        coordinator.invalidate() // Home / screen-off / destruction use the same invalidation.
        coordinator.resume()
        assertFalse(coordinator.acceptHeldCredential())
        assertNull(coordinator.complete(request, true))
    }

    @Test fun cancellationAndOldRequestCodeNeverAuthorizeANewChallenge() {
        val coordinator = NativeAuthenticationCoordinator()
        coordinator.resume()
        val first = coordinator.begin(mapOf("attemptId" to "one", "reason" to "Unlock", "fallbackLabel" to "Use device lock"))!!
        val oldChallenge = coordinator.prepareCredential(first, "old")!!
        coordinator.pause()
        assertEquals(CredentialChallengeResultDisposition.REJECTED,
            coordinator.credentialResult(oldChallenge.requestCode, false))
        coordinator.invalidate()
        coordinator.resume()
        val second = coordinator.begin(mapOf("attemptId" to "two", "reason" to "Unlock", "fallbackLabel" to "Use device lock"))!!
        val currentChallenge = coordinator.prepareCredential(second, "current")!!
        assertNotEquals(oldChallenge.requestCode, currentChallenge.requestCode)
        coordinator.pause()
        assertEquals(CredentialChallengeResultDisposition.REJECTED,
            coordinator.credentialResult(oldChallenge.requestCode, true))
        assertFalse(coordinator.acceptHeldCredential())
    }
}
