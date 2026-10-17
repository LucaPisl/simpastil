package com.simpastil.simpastil

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialPromptTransitionTest {
    @Test
    fun onlyOwnedCredentialLaunchConsumesOnePause() {
        val transition = CredentialPromptTransition()

        assertFalse(transition.consumeExpectedPause("attempt-1"))
        transition.arm("attempt-1")
        assertFalse(transition.consumeExpectedPause("other-attempt"))
        assertTrue(transition.consumeExpectedPause("attempt-1"))
        assertTrue(transition.ownsActiveTransition("attempt-1"))
        assertFalse(transition.consumeExpectedPause("attempt-1"))
    }

    @Test
    fun revokedAttemptCannotAuthorizeALaterPause() {
        val transition = CredentialPromptTransition()
        transition.arm("attempt-1")
        transition.clear("attempt-1")
        transition.arm("attempt-2")

        assertFalse(transition.consumeExpectedPause("attempt-1"))
        assertTrue(transition.consumeExpectedPause("attempt-2"))
        assertFalse(transition.ownsActiveTransition("attempt-1"))
    }

    @Test
    fun unrelatedActivityPauseIsNotOwnedByCredentialFlow() {
        val transition = CredentialPromptTransition()
        transition.arm("attempt-1")
        assertTrue(transition.consumeExpectedPause("attempt-1"))

        // Once resumed, a new pause has no armed launch token.
        transition.clear("attempt-1")
        assertFalse(transition.consumeExpectedPause("attempt-1"))
    }

    @Test
    fun successfulResultBeforeResumeIsHeldUntilTheSameChallengeResumes() {
        val token = CredentialChallengeResultToken("attempt-1", "challenge-1", 4)
        val beforeResume = CredentialChallengeResultState(
            activeAttemptId = "attempt-1",
            activeChallengeIdentity = "challenge-1",
            requestGeneration = 4,
            currentGeneration = 4,
            foreground = false,
            transitionOwned = true,
        )

        assertEquals(
            CredentialChallengeResultDisposition.HOLD_FOR_RESUME,
            CredentialChallengeResultGuard.onResult(true, token, beforeResume),
        )
        assertFalse(CredentialChallengeResultGuard.onResume(token, beforeResume))
        assertTrue(
            CredentialChallengeResultGuard.onResume(
                token,
                beforeResume.copy(foreground = true),
            ),
        )
    }

    @Test
    fun invalidationBetweenResultAndResumeRefusesTheHeldSuccess() {
        val token = CredentialChallengeResultToken("attempt-1", "challenge-1", 4)
        val beforeResume = CredentialChallengeResultState(
            activeAttemptId = "attempt-1",
            activeChallengeIdentity = "challenge-1",
            requestGeneration = 4,
            currentGeneration = 4,
            foreground = false,
            transitionOwned = true,
        )

        assertEquals(
            CredentialChallengeResultDisposition.HOLD_FOR_RESUME,
            CredentialChallengeResultGuard.onResult(true, token, beforeResume),
        )
        assertFalse(
            CredentialChallengeResultGuard.onResume(
                token,
                beforeResume.copy(foreground = true, currentGeneration = 5),
            ),
        )
        assertFalse(
            CredentialChallengeResultGuard.onResume(
                token,
                beforeResume.copy(foreground = true, transitionOwned = false),
            ),
        )
    }

    @Test
    fun canceledOrMismatchedChallengeCannotBeHeldOrAccepted() {
        val token = CredentialChallengeResultToken("attempt-1", "challenge-1", 4)
        val current = CredentialChallengeResultState(
            activeAttemptId = "attempt-1",
            activeChallengeIdentity = "challenge-1",
            requestGeneration = 4,
            currentGeneration = 4,
            foreground = true,
            transitionOwned = true,
        )

        assertEquals(
            CredentialChallengeResultDisposition.REJECTED,
            CredentialChallengeResultGuard.onResult(false, token, current),
        )
        assertEquals(
            CredentialChallengeResultDisposition.REJECTED,
            CredentialChallengeResultGuard.onResult(
                true,
                token,
                current.copy(activeAttemptId = "attempt-2"),
            ),
        )
        assertEquals(
            CredentialChallengeResultDisposition.REJECTED,
            CredentialChallengeResultGuard.onResult(
                true,
                token,
                current.copy(activeChallengeIdentity = "challenge-2"),
            ),
        )
        assertEquals(
            CredentialChallengeResultDisposition.REJECTED,
            CredentialChallengeResultGuard.onResult(
                true,
                token,
                current.copy(currentGeneration = 5),
            ),
        )
    }
}
