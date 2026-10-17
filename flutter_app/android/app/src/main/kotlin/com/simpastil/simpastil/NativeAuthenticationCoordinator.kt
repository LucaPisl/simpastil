package com.simpastil.simpastil

/** Activity-local authority: no token survives destruction or grants a later attempt access. */
internal class NativeAuthenticationCoordinator {
    class Attempt(val id: String, val reason: String, val fallbackLabel: String, val generation: Long)
    class Challenge(val request: Attempt, val requestCode: Int, val token: CredentialChallengeResultToken)

    var foreground = false
        private set
    var leaveGeneration = 0L
        private set
    var current: Attempt? = null
        private set
    var challenge: Challenge? = null
        private set
    private val transition = CredentialPromptTransition()
    private var heldCredentialSuccess = false
    private var nextRequestCode = 0x4000

    val credentialPromptAttemptId: String?
        get() = current?.id?.takeIf { transition.ownsActiveTransition(it) }

    fun context(): Map<String, Any?> = mapOf(
        "leaveGeneration" to leaveGeneration,
        "foreground" to foreground,
        "credentialPromptAttemptId" to credentialPromptAttemptId,
    )

    fun begin(arguments: Any?): Attempt? {
        val values = arguments as? Map<*, *> ?: return null
        if (values.keys != setOf("attemptId", "reason", "fallbackLabel")) return null
        val id = values["attemptId"] as? String ?: return null
        val reason = values["reason"] as? String ?: return null
        val fallbackLabel = values["fallbackLabel"] as? String ?: return null
        if (id.isBlank() || reason.isBlank() || fallbackLabel.isBlank() || !foreground || current != null) return null
        return Attempt(id, reason, fallbackLabel, leaveGeneration).also { current = it }
    }

    fun isCurrent(request: Attempt): Boolean = current === request &&
        leaveGeneration == request.generation

    fun prepareCredential(request: Attempt, identity: String): Challenge? {
        if (!isCurrent(request) || !foreground || challenge != null || identity.isBlank() ||
            nextRequestCode > 0xffff) return null
        val value = Challenge(request, nextRequestCode++,
            CredentialChallengeResultToken(request.id, identity, request.generation))
        transition.arm(request.id)
        challenge = value
        return value
    }

    /** True only for the one pause of an explicitly launched current challenge. */
    fun pause(): Boolean {
        foreground = false
        val request = current
        if (request != null && challenge?.request === request &&
            isCurrent(request) && transition.consumeExpectedPause(request.id)) return true
        invalidate()
        return false
    }

    fun resume(): String? {
        foreground = true
        return credentialPromptAttemptId
    }

    fun invalidate(): Attempt? {
        foreground = false
        leaveGeneration++
        val previous = current
        current = null
        challenge = null
        heldCredentialSuccess = false
        transition.clear()
        return previous
    }

    private fun challengeState(value: Challenge) = CredentialChallengeResultState(
        activeAttemptId = current?.id,
        activeChallengeIdentity = challenge?.token?.challengeIdentity,
        requestGeneration = value.request.generation,
        currentGeneration = leaveGeneration,
        foreground = foreground,
        transitionOwned = isCurrent(value.request) && transition.ownsActiveTransition(value.request.id),
    )

    fun credentialResult(requestCode: Int, succeeded: Boolean): CredentialChallengeResultDisposition {
        val value = challenge ?: return CredentialChallengeResultDisposition.REJECTED
        if (value.requestCode != requestCode || !isCurrent(value.request)) {
            return CredentialChallengeResultDisposition.REJECTED
        }
        val disposition = CredentialChallengeResultGuard.onResult(succeeded, value.token, challengeState(value))
        heldCredentialSuccess = disposition == CredentialChallengeResultDisposition.HOLD_FOR_RESUME
        return disposition
    }

    fun acceptHeldCredential(): Boolean {
        val value = challenge ?: return false
        return heldCredentialSuccess && isCurrent(value.request) &&
            CredentialChallengeResultGuard.onResume(value.token, challengeState(value))
    }

    fun complete(request: Attempt, authenticated: Boolean): Map<String, Any>? {
        if (current !== request) return null
        val accepted = authenticated && isCurrent(request) && foreground
        current = null
        challenge = null
        heldCredentialSuccess = false
        transition.clear()
        return mapOf("attemptId" to request.id, "authenticated" to accepted)
    }
}
