package com.simpastil.simpastil

/** Mirrors the persisted Flutter policy and fails closed on unknown values. */
internal object NativeAppLockPolicy {
    private val policyPattern = Regex(
        """\{"version":1,"enabled":(true|false),"revision":"[A-Za-z0-9_-]{1,128}"\}""",
    )

    fun isEnabled(policyValue: Any?, legacyValue: Any?): Boolean {
        if (policyValue == null) {
            return when (legacyValue) {
                null -> false
                is Boolean -> legacyValue
                else -> true
            }
        }
        if (policyValue !is String || policyValue.length > 8192) return true
        val match = policyPattern.matchEntire(policyValue) ?: return true
        return match.groupValues[1] == "true"
    }
}

internal enum class WidgetActionDestination {
    HEADLESS,
    FOREGROUND_REVIEW,
}

internal object WidgetActionRouting {
    fun destination(lockEnabled: Boolean): WidgetActionDestination =
        if (lockEnabled) {
            WidgetActionDestination.FOREGROUND_REVIEW
        } else {
            WidgetActionDestination.HEADLESS
        }
}
