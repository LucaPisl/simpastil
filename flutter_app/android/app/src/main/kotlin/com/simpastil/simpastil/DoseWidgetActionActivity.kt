package com.simpastil.simpastil

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/** Routes a user-tapped widget action according to the current durable policy. */
class DoseWidgetActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val actionUri = intent?.data
        val preferences = getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val lockEnabled = NativeAppLockPolicy.isEnabled(
            preferences.all["flutter.app_lock_policy_v1"],
            preferences.all["flutter.biometric_lock_enabled"],
        )

        when (WidgetActionRouting.destination(lockEnabled)) {
            WidgetActionDestination.HEADLESS -> dispatchHeadless(actionUri)
            WidgetActionDestination.FOREGROUND_REVIEW -> openProtectedReview(actionUri)
        }
        finish()
    }

    private fun dispatchHeadless(actionUri: android.net.Uri?) {
        if (actionUri == null) return
        val intent = Intent(BACKGROUND_ACTION).apply {
            component = ComponentName(
                packageName,
                "es.antonborri.home_widget.HomeWidgetBackgroundReceiver",
            )
            data = actionUri
        }
        sendBroadcast(intent)
    }

    private fun openProtectedReview(actionUri: android.net.Uri?) {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            data = actionUri
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        startActivity(intent)
    }

    private companion object {
        const val BACKGROUND_ACTION = "es.antonborri.home_widget.action.BACKGROUND"
    }
}
