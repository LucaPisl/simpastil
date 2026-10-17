package com.simpastil.simpastil

internal data class CredentialChallengeResultToken(
    val attemptId: String,
    val challengeIdentity: String,
    val generation: Long,
)

internal data class CredentialChallengeResultState(
    val activeAttemptId: String?,
    val activeChallengeIdentity: String?,
    val requestGeneration: Long,
    val currentGeneration: Long,
    val foreground: Boolean,
    val transitionOwned: Boolean,
)

internal enum class CredentialChallengeResultDisposition {
    REJECTED,
    HOLD_FOR_RESUME,
    ACCEPTED,
}

/** Binds a credential success to the exact live challenge and lifecycle. */
internal object CredentialChallengeResultGuard {
    fun onResult(
        succeeded: Boolean,
        token: CredentialChallengeResultToken,
        state: CredentialChallengeResultState,
    ): CredentialChallengeResultDisposition {
        if (!succeeded || !matches(token, state) || !state.transitionOwned) {
            return CredentialChallengeResultDisposition.REJECTED
        }
        return if (state.foreground) {
            CredentialChallengeResultDisposition.ACCEPTED
        } else {
            CredentialChallengeResultDisposition.HOLD_FOR_RESUME
        }
    }

    fun onResume(
        token: CredentialChallengeResultToken,
        state: CredentialChallengeResultState,
    ): Boolean = matches(token, state) && state.foreground && state.transitionOwned

    private fun matches(
        token: CredentialChallengeResultToken,
        state: CredentialChallengeResultState,
    ): Boolean = token.attemptId.isNotBlank() && token.challengeIdentity.isNotBlank() &&
        state.activeAttemptId == token.attemptId &&
        state.activeChallengeIdentity == token.challengeIdentity &&
        state.requestGeneration == token.generation &&
        state.currentGeneration == token.generation
}

/** Owns the one activity pause caused by a credential challenge we launched. */
internal class CredentialPromptTransition {
    private var expectedPauseAttemptId: String? = null
    private var activeAttemptId: String? = null

    fun arm(attemptId: String) {
        require(attemptId.isNotBlank())
        check(activeAttemptId == null) { "A credential transition is already active" }
        expectedPauseAttemptId = attemptId
    }

    fun consumeExpectedPause(attemptId: String): Boolean {
        if (expectedPauseAttemptId != attemptId || activeAttemptId != null) return false
        expectedPauseAttemptId = null
        activeAttemptId = attemptId
        return true
    }

    fun ownsActiveTransition(attemptId: String): Boolean =
        activeAttemptId == attemptId

    fun clear(attemptId: String? = null) {
        if (attemptId == null || expectedPauseAttemptId == attemptId) {
            expectedPauseAttemptId = null
        }
        if (attemptId == null || activeAttemptId == attemptId) {
            activeAttemptId = null
        }
    }
}
