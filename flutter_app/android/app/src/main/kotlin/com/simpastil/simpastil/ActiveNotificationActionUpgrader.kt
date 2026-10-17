package com.simpastil.simpastil

import android.app.Notification
import android.app.ActivityOptions
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** The caller must validate the complete published payload under its current access lease. */
internal data class ActiveNotificationActionEnvelope(
    val id: Int,
    val tag: String?,
    val payload: String,
    val actions: List<ForegroundNotificationAction>,
) {
    fun extras(index: Int): Map<String, Any?> = mapOf(
        "notificationId" to id,
        "notificationTag" to tag,
        "actionId" to actions[index].id,
        "cancelNotification" to actions[index].cancelNotification,
        "payload" to payload,
    )

    fun matches(id: Int, tag: String?, owner: String, creators: List<String?>): Boolean =
        this.id == id && this.tag == tag && creators.size == actions.size &&
            creators.all { it == owner }

    companion object {
        const val FOREGROUND_ACTION = "SELECT_FOREGROUND_NOTIFICATION"
        private val careActions = listOf("taken", "snooze", "skip")

        fun parseBatch(arguments: Any?): List<ActiveNotificationActionEnvelope>? {
            val root = arguments as? Map<*, *> ?: return null
            if (root.keys != setOf("envelopes")) return null
            val values = root["envelopes"] as? List<*> ?: return null
            val result = mutableListOf<ActiveNotificationActionEnvelope>()
            val ids = mutableSetOf<Int>()
            for (value in values) {
                val item = value as? Map<*, *> ?: return null
                if (item.keys != setOf("id", "tag", "payload", "actions")) return null
                val id = item["id"] as? Int ?: return null
                if (id < 0 || !ids.add(id)) return null
                val tag = item["tag"]
                if (tag != null && tag !is String) return null
                val payload = item["payload"] as? String ?: return null
                if (payload.isBlank()) return null
                val actionValues = item["actions"] as? List<*> ?: return null
                if (actionValues.size != careActions.size) return null
                val actions = actionValues.mapIndexed { index, actionValue ->
                    val action = actionValue as? Map<*, *> ?: return null
                    if (action.keys != setOf("id", "cancelNotification") ||
                        action["id"] != careActions[index]) return null
                    ForegroundNotificationAction(
                        careActions[index], action["cancelNotification"] as? Boolean ?: return null,
                    )
                }
                result.add(ActiveNotificationActionEnvelope(id, tag as String?, payload, actions))
            }
            return result
        }
    }
}

internal data class ForegroundNotificationAction(val id: String, val cancelNotification: Boolean)

internal object ActiveNotificationActionUpgrader {
    fun refresh(context: Context, envelopes: List<ActiveNotificationActionEnvelope>): Map<String, List<Int>> {
        val activeIds = mutableListOf<Int>()
        val refreshed = mutableListOf<Int>()
        val skipped = mutableListOf<Int>()
        val failed = mutableListOf<Int>()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val active = try {
            manager.activeNotifications
        } catch (_: Exception) {
            return mapOf("active" to activeIds, "refreshed" to refreshed,
                "skipped" to skipped, "failed" to envelopes.map { it.id })
        }
        for (envelope in envelopes) {
            val existing = active.singleOrNull {
                it.packageName == context.packageName && it.id == envelope.id && it.tag == envelope.tag
            }
            val notification = existing?.notification
            val actions = notification?.actions
            if (existing == null || notification == null || actions == null ||
                !envelope.matches(existing.id, existing.tag, context.packageName,
                    actions.map { it.actionIntent?.creatorPackage })) {
                skipped.add(envelope.id)
                continue
            }
            activeIds.add(envelope.id)
            try {
                val replacements = actions.mapIndexed { index, original ->
                    val intent = Intent(context, MainActivity::class.java)
                        .setAction(ActiveNotificationActionEnvelope.FOREGROUND_ACTION)
                        .addCategory(Intent.CATEGORY_LAUNCHER)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    for ((key, value) in envelope.extras(index)) {
                        when (value) {
                            is Int -> intent.putExtra(key, value)
                            is Boolean -> intent.putExtra(key, value)
                            is String -> intent.putExtra(key, value)
                            null -> intent.putExtra(key, null as String?)
                        }
                    }
                    val options = if (Build.VERSION.SDK_INT >= 35) ActivityOptions.makeBasic().apply {
                        setPendingIntentCreatorBackgroundActivityStartMode(
                            ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                        )
                    }.toBundle() else null
                    val pending = PendingIntent.getActivity(context, envelope.id * 16 + index, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE, options)
                    val builder = Notification.Action.Builder(original.getIcon(), original.title, pending)
                        .addExtras(original.extras)
                        .setAllowGeneratedReplies(original.allowGeneratedReplies)
                    original.remoteInputs?.forEach { builder.addRemoteInput(it) }
                    if (Build.VERSION.SDK_INT >= 28) builder.setSemanticAction(original.semanticAction)
                    if (Build.VERSION.SDK_INT >= 29) builder.setContextual(original.isContextual)
                    if (Build.VERSION.SDK_INT >= 31) builder.setAuthenticationRequired(original.isAuthenticationRequired)
                    // NotificationCompat records this hint in extras as well as in its PendingIntent type.
                    builder.addExtras(android.os.Bundle().apply { putBoolean("android.support.action.showsUserInterface", true) })
                    builder.build()
                }.toTypedArray()
                val updated = Notification.Builder.recoverBuilder(context, notification)
                    .setActions(*replacements)
                    .setOnlyAlertOnce(true)
                    .build()
                manager.notify(existing.tag, existing.id, updated)
                refreshed.add(envelope.id)
            } catch (_: Exception) {
                failed.add(envelope.id)
            }
        }
        return mapOf("active" to activeIds, "refreshed" to refreshed,
            "skipped" to skipped, "failed" to failed)
    }
}
