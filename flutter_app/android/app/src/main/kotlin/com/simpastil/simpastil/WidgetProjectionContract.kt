package com.simpastil.simpastil

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Calendar
import java.util.TimeZone
import java.util.UUID

/**
 * Cross-runtime widget identity contract. Keep keys and canonical arrays in
 * lockstep with preference_keys.dart and contracts/fixtures/projection-command-ids-v1.json;
 * android/app/src/test/.../WidgetSessionContractTest.kt pins this contract.
 */
internal data class WidgetGrantIdentity(val version: Int, val workspaceId: String, val ownerId: String, val grantEpoch: Long)

internal object WidgetProjectionContract {
    const val snapshotKey = "today_doses"
    const val snapshotDayKey = "snapshot_day"
    const val appThemeModeKey = "app_theme_mode"
    const val activeUserIdKey = "active_user_id"
    const val sessionGenerationKey = "session_generation"
    const val projectionIdentityKey = "widget_projection_identity_v2"
    const val retirementIntentKey = "widget_projection_retirement_v2"

    /** Row fields the medication look travels in (see WidgetMedicationLook). */
    const val rowShapeField = "shape"
    const val rowImprintField = "imprint"

    private val dnsNamespace = UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

    /**
     * A snapshot describes one local day. After midnight or a clock/timezone
     * change it must not offer yesterday's rows as actionable.
     */
    fun snapshotIsCurrent(snapshotDay: String?, today: String): Boolean =
        snapshotDay != null && snapshotDay == today

    /** Epoch millis of 00:01 local time on the day after [nowMillis] in [zone]. */
    fun nextMidnightUpdateMillis(nowMillis: Long, zone: TimeZone): Long =
        Calendar.getInstance(zone).apply {
            timeInMillis = nowMillis
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 1)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

    fun snapshotIdentityMatches(
        authenticated: Boolean,
        snapshotOwner: String?,
        snapshotGeneration: Long?,
        activeOwner: String?,
        activeGeneration: Long?,
    ): Boolean = authenticated &&
        !snapshotOwner.isNullOrBlank() &&
        snapshotOwner == activeOwner &&
        snapshotGeneration != null &&
        snapshotGeneration >= 0 &&
        snapshotGeneration == activeGeneration

    fun protectedSnapshotIdentityMatches(
        snapshot: WidgetGrantIdentity?, marker: WidgetGrantIdentity?,
        snapshotOwner: String?, snapshotGeneration: Long?, activeOwner: String?, activeGeneration: Long?,
    ): Boolean = validIdentity(snapshot) && snapshot == marker &&
        snapshotIdentityMatches(true, snapshotOwner, snapshotGeneration, activeOwner, activeGeneration) &&
        snapshotOwner == snapshot!!.ownerId && snapshotGeneration == snapshot.grantEpoch

    fun validIdentity(identity: WidgetGrantIdentity?): Boolean = identity != null &&
        identity.version == 2 && isCanonicalUuid(identity.workspaceId) &&
        validOwner(identity.ownerId) && identity.grantEpoch > 0

    private fun validOwner(owner: String): Boolean = isCanonicalUuid(owner) ||
        (owner.startsWith("local:") && isCanonicalUuid(owner.removePrefix("local:")))

    fun widgetProjectionCanonicalKey(
        activeUserId: String, sessionGeneration: Int, occurrenceId: String,
        workspaceId: String? = null, grantEpoch: Long? = null, stateVersion: Long? = null,
    ): String {
        if (workspaceId == null && grantEpoch == null && stateVersion == null) {
            return "[1,\"$activeUserId\",$sessionGeneration,\"$occurrenceId\",\"widget\"]"
        }
        require(workspaceId != null && grantEpoch != null && stateVersion != null)
        require(validIdentity(WidgetGrantIdentity(2, workspaceId, activeUserId, grantEpoch)))
        require(grantEpoch == sessionGeneration.toLong() && stateVersion >= 0 && isCanonicalUuid(occurrenceId))
        return "[2,\"$workspaceId\",$grantEpoch,\"$activeUserId\",\"$occurrenceId\",\"widget\",$stateVersion]"
    }

    fun widgetProjectionId(
        activeUserId: String, sessionGeneration: Int, occurrenceId: String,
        workspaceId: String? = null, grantEpoch: Long? = null, stateVersion: Long? = null,
    ): String {
        require(isCanonicalUuid(occurrenceId))
        require(if (workspaceId == null) isCanonicalUuid(activeUserId) else validOwner(activeUserId))
        require(sessionGeneration >= 0)
        return uuidV5(widgetProjectionCanonicalKey(activeUserId, sessionGeneration, occurrenceId,
            workspaceId, grantEpoch, stateVersion))
    }

    fun widgetActionCanonicalKey(
        projectionId: String,
        occurrenceId: String,
        action: String,
    ): String {
        require(action == "take" || action == "skip")
        return "[1,\"$projectionId\",\"$occurrenceId\",\"$action\"]"
    }

    fun widgetActionCommandId(
        projectionId: String,
        occurrenceId: String,
        action: String,
    ): String = uuidV5(widgetActionCanonicalKey(projectionId, occurrenceId, action))

    fun actionQueryParameters(
        action: String, activeUserId: String?, sessionGeneration: Int,
        occurrenceId: String, projectionId: String,
        workspaceId: String? = null, grantEpoch: Long? = null, stateVersion: Long? = null,
    ): Map<String, String>? {
        if ((action != "take" && action != "skip") || activeUserId.isNullOrBlank() ||
            sessionGeneration < 0 || !isCanonicalUuid(occurrenceId) || !isCanonicalUuid(projectionId)) return null
        val expected = runCatching { widgetProjectionId(activeUserId, sessionGeneration, occurrenceId,
            workspaceId, grantEpoch, stateVersion) }.getOrNull() ?: return null
        if (projectionId != expected) return null
        val identity = mapOf(activeUserIdKey to activeUserId,
            sessionGenerationKey to sessionGeneration.toString(), "occurrenceId" to occurrenceId, "projectionId" to projectionId)
        return if (workspaceId == null) identity else identity + mapOf(
            "version" to "2", "workspaceId" to workspaceId, "grantEpoch" to grantEpoch.toString(), "stateVersion" to stateVersion.toString())
    }

    fun uuidV5(canonicalKey: String): String {
        val namespace = ByteBuffer.allocate(16)
            .putLong(dnsNamespace.mostSignificantBits)
            .putLong(dnsNamespace.leastSignificantBits)
            .array()
        val name = canonicalKey.toByteArray(StandardCharsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-1").digest(namespace + name)
        digest[6] = ((digest[6].toInt() and 0x0f) or 0x50).toByte()
        digest[8] = ((digest[8].toInt() and 0x3f) or 0x80).toByte()
        val uuidBytes = ByteBuffer.wrap(digest.copyOfRange(0, 16))
        return UUID(uuidBytes.long, uuidBytes.long).toString()
    }

    private fun isCanonicalUuid(value: String): Boolean = runCatching {
        UUID.fromString(value).toString() == value.lowercase()
    }.getOrDefault(false)
}
