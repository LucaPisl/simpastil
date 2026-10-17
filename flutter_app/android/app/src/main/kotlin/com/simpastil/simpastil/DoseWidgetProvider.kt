package com.simpastil.simpastil

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import java.text.SimpleDateFormat
import java.time.LocalDateTime
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class DoseWidgetProvider : AppWidgetProvider() {

    private companion object {
        const val MIDNIGHT_REQUEST_CODE = 0x51D
        const val MIDNIGHT_WINDOW_MILLIS = 15 * 60 * 1000L
    }

    // The day, clock or timezone changed: re-render now so yesterday's rows are
    // withdrawn instead of waiting for the periodic update.
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            Intent.ACTION_DATE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED -> {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, DoseWidgetProvider::class.java),
                )
                if (ids.isNotEmpty()) onUpdate(context, manager, ids)
            }
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        val raw = currentSnapshot(prefs)
        val snapshotDay = if (raw != null) {
            prefs.getString(WidgetProjectionContract.snapshotDayKey, null)
        } else {
            null
        }
        val today = todayKey()
        val values = prefs.all
        val activeOwner = values[WidgetProjectionContract.activeUserIdKey] as? String
        val activeGeneration = WidgetPresentationGuard.integer(
            values[WidgetProjectionContract.sessionGenerationKey],
        ) ?: -1L

        if (!activeOwner.isNullOrBlank() && activeGeneration >= 0 &&
            (raw == null || snapshotDay != today)
        ) {
            val refreshIntent = Intent("es.antonborri.home_widget.action.BACKGROUND").apply {
                component = ComponentName(
                    context.packageName,
                    "es.antonborri.home_widget.HomeWidgetBackgroundReceiver",
                )
                this.data = Uri.parse("simpastil://refresh")
            }
            PendingIntent.getBroadcast(
                context,
                0,
                refreshIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ).send()
        }

        for (appWidgetId in appWidgetIds) {
            val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
            val views = buildViews(context, raw, appWidgetId, options)
            appWidgetManager.updateAppWidget(appWidgetId, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        }
        scheduleMidnightUpdate(context)
    }

    // DATE_CHANGED is not delivered to manifest receivers on Android 8+, so an
    // inexact alarm just after local midnight re-renders the widget for the new
    // day. It is re-armed on every update and replaces the previous one.
    private fun scheduleMidnightUpdate(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = midnightPendingIntent(context, create = true) ?: return
        val at = WidgetProjectionContract.nextMidnightUpdateMillis(
            System.currentTimeMillis(),
            TimeZone.getDefault(),
        )
        // A window lets the system batch the alarm: it fires within 15 minutes
        // after 00:01 without waking the device or needing exact-alarm access.
        alarms.setWindow(AlarmManager.RTC, at, MIDNIGHT_WINDOW_MILLIS, pending)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        midnightPendingIntent(context, create = false)?.let {
            alarms.cancel(it)
            it.cancel()
        }
    }

    private fun midnightPendingIntent(context: Context, create: Boolean): PendingIntent? {
        val intent = Intent(context, DoseWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            if (create) {
                putExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_IDS,
                    AppWidgetManager.getInstance(context).getAppWidgetIds(
                        ComponentName(context, DoseWidgetProvider::class.java),
                    ),
                )
            }
        }
        val flags = if (create) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, MIDNIGHT_REQUEST_CODE, intent, flags)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        val raw = currentSnapshot(prefs)
        val views = buildViews(context, raw, appWidgetId, newOptions)
        appWidgetManager.updateAppWidget(appWidgetId, views)
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
    }

    private fun todayKey(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    private fun currentSnapshot(prefs: android.content.SharedPreferences): String? =
        currentProtectedWidgetSnapshot(prefs)?.toString()

    private fun isDarkMode(context: Context): Boolean {
        val prefs = HomeWidgetPlugin.getData(context)
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

    private fun buildViews(
        context: Context,
        raw: String?,
        appWidgetId: Int,
        options: Bundle,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.dose_widget)
        val colors = WidgetColors(isDarkMode(context))
        // Portrait size: min width x max height, as the launcher reports it.
        val widthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            .takeIf { it > 0 } ?: 250
        val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
        val tier = WidgetSky.tier(heightDp)

        views.setInt(
            R.id.widget_root,
            "setBackgroundResource",
            if (colors.dark) R.drawable.widget_background_dark else R.drawable.widget_background,
        )
        views.setTextColor(R.id.widget_title, colors.inkMuted)
        views.setViewVisibility(
            R.id.widget_title,
            if (tier == WidgetTier.SMALL) View.GONE else View.VISIBLE,
        )
        views.setTextViewText(R.id.widget_today, context.getString(R.string.widget_today))
        views.setTextColor(R.id.widget_today, colors.ink)
        views.setFloat(R.id.widget_today, "setTextSize", if (tier == WidgetTier.SMALL) 15f else 18f)
        views.setTextColor(R.id.widget_compact_info, colors.ink)
        views.setInt(
            R.id.widget_compact_info,
            "setBackgroundResource",
            if (colors.dark) R.drawable.widget_summary_bg_dark else R.drawable.widget_summary_bg,
        )
        views.setTextColor(R.id.widget_empty_text, colors.inkMuted)
        views.setTextColor(R.id.widget_list_empty, colors.inkMuted)

        views.setOnClickPendingIntent(
            R.id.widget_header,
            HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
        )
        views.setOnClickPendingIntent(
            R.id.widget_empty_text,
            HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
        )

        val adapterIntent = Intent(context, DoseWidgetService::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            this.data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
        }
        views.setRemoteAdapter(R.id.widget_list, adapterIntent)
        views.setEmptyView(R.id.widget_list, R.id.widget_list_empty)
        views.setTextViewText(
            R.id.widget_list_empty,
            context.getString(R.string.widget_resize_hint),
        )

        val templateIntent = Intent("es.antonborri.home_widget.action.BACKGROUND").apply {
            component = ComponentName(
                context.packageName,
                "es.antonborri.home_widget.HomeWidgetBackgroundReceiver",
            )
        }
        views.setPendingIntentTemplate(
            R.id.widget_list,
            PendingIntent.getBroadcast(
                context,
                appWidgetId,
                templateIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            ),
        )

        val now = LocalDateTime.now()
        val minute = now.hour * 60.0 + now.minute
        fun sky(marks: List<SkyMark>, empty: Boolean) {
            val bitmap = WidgetSkyRenderer.renderSky(
                widthDp = widthDp,
                heightDp = WidgetSky.skyHeightDp(tier, empty),
                density = context.resources.displayMetrics.density,
                colors = colors,
                date = now.toLocalDate(),
                minute = minute,
                marks = marks,
                tier = tier,
            )
            views.setImageViewBitmap(R.id.widget_sky, bitmap)
        }
        fun message(text: String) {
            sky(emptyList(), empty = true)
            views.setViewVisibility(R.id.widget_list, View.GONE)
            views.setViewVisibility(R.id.widget_list_empty, View.GONE)
            views.setViewVisibility(R.id.widget_compact_info, View.GONE)
            views.setViewVisibility(R.id.widget_empty_text, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty_text, text)
            views.setContentDescription(
                R.id.widget_header,
                "${context.getString(R.string.widget_today)}. $text",
            )
        }

        val current = currentProtectedWidgetSnapshot(HomeWidgetPlugin.getData(context))
        val snapshot = current?.takeIf { it.toString() == raw }
        if (snapshot == null) {
            message(context.getString(R.string.widget_open_app))
            return views
        }

        // Yesterday's snapshot stays non-actionable until the app republishes.
        val snapshotDay = HomeWidgetPlugin.getData(context)
            .getString(WidgetProjectionContract.snapshotDayKey, null)
        if (!WidgetProjectionContract.snapshotIsCurrent(snapshotDay, todayKey())) {
            message(context.getString(R.string.widget_open_app))
            return views
        }

        // Privacy is independent of app lock. A valid private snapshot exposes
        // only the existing app-open intent, never progress, labels or actions.
        // The sky itself depends only on the clock, so it carries no care data.
        if (WidgetPresentationGuard.privatePresentation(snapshot.presentationFields())) {
            message(context.getString(R.string.widget_open_app))
            return views
        }

        val taken = snapshot.optInt("taken", 0)
        val total = snapshot.optInt("total", 0)
        val dosesCount = snapshot.optJSONArray("doses")?.length() ?: 0

        if (total == 0 && dosesCount == 0) {
            message(context.getString(R.string.widget_nothing_scheduled))
            return views
        }

        // Marks come only from rows the collection itself would display.
        val identity = snapshot.optJSONObject("projectionIdentity")?.let {
            WidgetPresentationGuard.identity(it.presentationFields())
        }
        val marks = mutableListOf<SkyMark>()
        val statuses = mutableListOf<String?>()
        snapshot.optJSONArray("doses")?.let { rows ->
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val fields = row.presentationFields()
                if (!WidgetPresentationGuard.canDisplayRow(fields, identity)) continue
                if (row.optBoolean("isPrn", false)) continue
                val status = row.optString("status")
                statuses += status
                val m = WidgetSky.minuteOf(row.optString("time")) ?: continue
                marks += SkyMark(m, WidgetSky.capsuleState(status, false))
            }
        }

        val summary = when (val s = WidgetSky.summarize(taken, total, statuses)) {
            DaySummary.NothingScheduled -> context.getString(R.string.widget_nothing_scheduled)
            DaySummary.AllRecorded -> context.getString(R.string.widget_all_recorded)
            is DaySummary.Progress -> context.getString(R.string.widget_taken_of_total, s.taken, s.total)
        }
        sky(marks, empty = false)
        views.setViewVisibility(R.id.widget_empty_text, View.GONE)
        views.setViewVisibility(R.id.widget_list, View.VISIBLE)
        views.setViewVisibility(R.id.widget_compact_info, View.VISIBLE)
        views.setTextViewText(R.id.widget_compact_info, summary)
        views.setContentDescription(
            R.id.widget_header,
            "${context.getString(R.string.widget_today)}. $summary",
        )
        return views
    }
}
