package com.simpastil.simpastil

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

// Presentation decisions are shared by the header and collection rows. The
// platform adapter supplies raw JSON values so malformed types stay untrusted.
internal object WidgetPresentationGuard {
    fun privatePresentation(snapshot: Map<String, Any?>): Boolean = snapshot["private"] == true

    fun integer(value: Any?): Long? = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }

    fun identity(fields: Map<*, *>?): WidgetGrantIdentity? {
        if (fields == null || integer(fields["version"]) != 2L) return null
        val workspace = fields["workspaceId"] as? String ?: return null
        val owner = fields["userId"] as? String ?: return null
        val epoch = integer(fields["grantEpoch"]) ?: return null
        return WidgetGrantIdentity(2, workspace, owner, epoch)
            .takeIf(WidgetProjectionContract::validIdentity)
    }

    fun canDisplaySnapshot(
        snapshot: Map<String, Any?>,
        marker: Map<String, Any?>?,
        owner: String?,
        epoch: Long?,
    ): Boolean = snapshot["authenticated"] == true &&
        WidgetProjectionContract.protectedSnapshotIdentityMatches(
            identity(snapshot["projectionIdentity"] as? Map<*, *>),
            identity(marker),
            snapshot["active_user_id"] as? String,
            integer(snapshot["session_generation"]),
            owner,
            epoch,
        )

    fun canDisplayRow(row: Map<String, Any?>, current: WidgetGrantIdentity?): Boolean {
        if (current == null || !WidgetProjectionContract.validIdentity(current) || identity(row) != current ||
            row["active_user_id"] != current.ownerId ||
            integer(row["session_generation"]) != current.grantEpoch
        ) return false
        return when (row["rowKind"]) {
            "scheduled" -> (!row.containsKey("isPrn") || row["isPrn"] == false) &&
                integer(row["stateVersion"])?.let { it >= 0 } == true
            "prnSummary" -> row["isPrn"] == true &&
                listOf("occurrenceId", "projectionId", "stateVersion").none(row::containsKey)
            else -> false
        }
    }

    fun actionParameters(row: Map<String, Any?>, current: WidgetGrantIdentity?): Map<String, String>? {
        if (current == null || !canDisplayRow(row, current) || row["rowKind"] != "scheduled" ||
            row["status"] != "pending" || current.grantEpoch > Int.MAX_VALUE
        ) return null
        return WidgetProjectionContract.actionQueryParameters(
            action = "take",
            activeUserId = current.ownerId,
            sessionGeneration = current.grantEpoch.toInt(),
            occurrenceId = row["occurrenceId"] as? String ?: "",
            projectionId = row["projectionId"] as? String ?: "",
            workspaceId = current.workspaceId,
            grantEpoch = current.grantEpoch,
            stateVersion = integer(row["stateVersion"]),
        )
    }
}

internal fun JSONObject.presentationFields(): Map<String, Any?> =
    keys().asSequence().associateWith { key ->
        val value = opt(key)
        if (key == "projectionIdentity" && value is JSONObject) value.presentationFields() else value
    }

internal fun currentProtectedWidgetSnapshot(prefs: android.content.SharedPreferences): JSONObject? {
    val values = prefs.all
    val raw = values[WidgetProjectionContract.snapshotKey] as? String ?: return null
    val snapshot = runCatching { JSONObject(raw) }.getOrNull() ?: return null
    val marker = (values[WidgetProjectionContract.projectionIdentityKey] as? String)?.let {
        runCatching { JSONObject(it).presentationFields() }.getOrNull()
    }
    return snapshot.takeIf {
        WidgetPresentationGuard.canDisplaySnapshot(
            snapshot.presentationFields(), marker,
            values[WidgetProjectionContract.activeUserIdKey] as? String,
            WidgetPresentationGuard.integer(values[WidgetProjectionContract.sessionGenerationKey]),
        )
    }
}

class DoseWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return DoseRemoteViewsFactory(applicationContext)
    }
}

private class DoseRemoteViewsFactory(
    private val context: Context,
) : RemoteViewsService.RemoteViewsFactory {

    private var doses = JSONArray()
    private var dark = false
    private var locale: Locale = Locale.getDefault()
    private var clockPattern = "HH:mm"
    private var identity: WidgetGrantIdentity? = null
    private var snapshotBody: String? = null

    override fun onCreate() {}

    override fun onDataSetChanged() {
        val data = HomeWidgetPlugin.getData(context)
        dark = isDarkMode(data)
        // Rows say their time as the phone does: 24-hour when it says so,
        // otherwise the language's own clock.
        locale = context.resources.configuration.locales[0]
        clockPattern = DateFormat.getBestDateTimePattern(
            locale,
            if (DateFormat.is24HourFormat(context)) "Hm" else "jm",
        )
        val snapshot = currentProtectedWidgetSnapshot(data)
        identity = snapshot?.optJSONObject("projectionIdentity")?.let {
            WidgetPresentationGuard.identity(it.presentationFields())
        }
        snapshotBody = snapshot?.toString()
        doses = JSONArray()
        if (snapshot != null && WidgetPresentationGuard.privatePresentation(snapshot.presentationFields())) return
        val candidates = snapshot?.optJSONArray("doses") ?: return
        for (index in 0 until candidates.length()) {
            val dose = candidates.optJSONObject(index) ?: continue
            if (WidgetPresentationGuard.canDisplayRow(dose.presentationFields(), identity)) {
                doses.put(dose)
            }
        }
    }

    private fun isDarkMode(prefs: android.content.SharedPreferences): Boolean {
        val themeMode = prefs.getString(WidgetProjectionContract.appThemeModeKey, null)
        return when (themeMode) {
            "dark" -> true
            "light" -> false
            else -> {
                val uiMode = context.resources.configuration.uiMode and
                    Configuration.UI_MODE_NIGHT_MASK
                uiMode == Configuration.UI_MODE_NIGHT_YES
            }
        }
    }

    override fun onDestroy() {
        doses = JSONArray()
        identity = null
        snapshotBody = null
    }

    override fun getCount(): Int = doses.length()

    override fun getViewAt(position: Int): RemoteViews {
        val row = RemoteViews(context.packageName, R.layout.dose_widget_row)
        // RemoteViews may be reapplied to a recycled view with an old label or
        // Take target. Explicitly clear it even when this request is refused.
        row.setViewVisibility(R.id.row_root, View.GONE)
        row.setTextViewText(R.id.row_pill, "")
        row.setTextViewText(R.id.row_time, "")
        row.setTextViewText(R.id.row_check, "")
        row.setOnClickFillInIntent(R.id.row_root, Intent())
        // A collection factory can outlive a native publication or retirement.
        // Recheck before assigning any care label or click target to this row.
        val current = currentProtectedWidgetSnapshot(HomeWidgetPlugin.getData(context))
        if (position < 0 || position >= doses.length() || current == null ||
            current.toString() != snapshotBody
        ) return row

        val dose = doses.getJSONObject(position)
        val fields = dose.presentationFields()
        if (!WidgetPresentationGuard.canDisplayRow(fields, identity)) return row
        row.setViewVisibility(R.id.row_root, View.VISIBLE)
        val status = dose.optString("status")
        val pillColor = dose.optString("color", "")
        val isPrn = dose.optBoolean("isPrn", false)
        val colors = WidgetColors(dark)

        val cardBgRes = if (dark) R.drawable.widget_card_bg_dark else R.drawable.widget_card_bg
        val takeBtnRes = if (dark) R.drawable.widget_take_btn_dark else R.drawable.widget_take_btn
        val takenBgRes = if (dark) R.drawable.widget_status_taken_bg_dark else R.drawable.widget_status_taken_bg
        val missedBgRes = if (dark) R.drawable.widget_status_missed_bg_dark else R.drawable.widget_status_missed_bg
        val skippedBgRes = if (dark) R.drawable.widget_status_skipped_bg_dark else R.drawable.widget_status_skipped_bg
        val highlightRes = if (dark) R.drawable.widget_row_highlight_dark else R.drawable.widget_row_highlight

        row.setTextViewText(R.id.row_pill, dose.optString("pill"))
        row.setTextViewText(
            R.id.row_time,
            WidgetSky.clockLabel(dose.optString("time"), clockPattern, locale),
        )
        row.setTextColor(R.id.row_pill, colors.ink)
        row.setTextColor(R.id.row_time, colors.inkMuted)

        val medicationColor = pillColor.takeIf { it.isNotEmpty() }?.let {
            runCatching { android.graphics.Color.parseColor(it) }.getOrNull()
        }
        val state = WidgetSky.capsuleState(status, isPrn)
        val capsule = WidgetCapsuleLayers.forState(state, colors, medicationColor ?: colors.lavender)
        row.setInt(R.id.row_capsule_fill, "setColorFilter", capsule.fill)
        row.setViewVisibility(R.id.row_capsule_half, if (capsule.half != null) View.VISIBLE else View.GONE)
        capsule.half?.let { row.setInt(R.id.row_capsule_half, "setColorFilter", it) }
        row.setImageViewResource(
            R.id.row_accent,
            when (capsule.shape) {
                CapsuleStroke.RIM -> R.drawable.widget_capsule_rim
                CapsuleStroke.OUTLINE -> R.drawable.widget_capsule_outline
                CapsuleStroke.SKIPPED -> R.drawable.widget_capsule_skipped
            },
        )
        row.setInt(R.id.row_accent, "setColorFilter", capsule.stroke)

        fun chip(text: String, textColor: Int, bg: Int) {
            row.setTextViewText(R.id.row_check, text)
            row.setTextColor(R.id.row_check, textColor)
            row.setInt(R.id.row_check, "setBackgroundResource", bg)
        }

        if (isPrn) {
            row.setInt(R.id.row_root, "setBackgroundResource", cardBgRes)
            chip("", colors.inkMuted, 0)
            return row
        }

        when (status) {
            "taken" -> {
                row.setInt(R.id.row_root, "setBackgroundResource", cardBgRes)
                chip(context.getString(R.string.widget_status_taken), colors.sage, takenBgRes)
            }
            "missed" -> {
                row.setInt(R.id.row_root, "setBackgroundResource", cardBgRes)
                chip(context.getString(R.string.widget_status_missed), colors.inkMuted, missedBgRes)
            }
            "skipped" -> {
                row.setInt(R.id.row_root, "setBackgroundResource", cardBgRes)
                chip(context.getString(R.string.widget_status_skipped), colors.inkMuted, skippedBgRes)
            }
            else -> {
                val actionIdentity = WidgetPresentationGuard.actionParameters(fields, identity)
                if (actionIdentity != null) {
                    row.setInt(R.id.row_root, "setBackgroundResource", highlightRes)
                    chip(context.getString(R.string.widget_take), colors.onPrimary, takeBtnRes)
                    val builder = Uri.Builder().scheme("simpastil").authority("take")
                    actionIdentity.forEach { (key, value) ->
                        builder.appendQueryParameter(key, value)
                    }
                    val fillIntent = Intent().apply { data = builder.build() }
                    row.setOnClickFillInIntent(R.id.row_root, fillIntent)
                } else {
                    row.setInt(R.id.row_root, "setBackgroundResource", cardBgRes)
                    chip("—", colors.inkMuted, skippedBgRes)
                }
            }
        }

        return row
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}
