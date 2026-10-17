package com.simpastil.simpastil

import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterFragmentActivity() {
    private class PendingAuthentication(
        val attempt: NativeAuthenticationCoordinator.Attempt,
        val result: MethodChannel.Result,
        val fallbackLabel: String = attempt.fallbackLabel,
        var prompt: BiometricPrompt? = null,
    )

    private val coordinator = NativeAuthenticationCoordinator()
    private var channel: MethodChannel? = null
    private var pending: PendingAuthentication? = null
    private var receiverRegistered = false
    private val interruptionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val home = intent.action == Intent.ACTION_CLOSE_SYSTEM_DIALOGS &&
                intent.getStringExtra("reason") in setOf("homekey", "recentapps")
            if (intent.action == Intent.ACTION_SCREEN_OFF || home) invalidateAccess()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        refreshProtection()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(interruptionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(interruptionReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.simpastil/app_lock")
            .also { it.setMethodCallHandler(::handleAccessCall) }
    }

    private fun handleAccessCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "context" -> result.success(coordinator.context())
            "refreshPolicy" -> {
                refreshProtection()
                result.success(null)
            }
            "authenticate" -> authenticate(call.arguments, result)
            "refreshActiveNotificationActions" -> {
                val envelopes = ActiveNotificationActionEnvelope.parseBatch(call.arguments)
                if (envelopes == null) {
                    result.error("invalid_arguments", "Invalid notification action envelopes", null)
                } else {
                    result.success(ActiveNotificationActionUpgrader.refresh(this, envelopes))
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        // flutter_local_notifications and home_widget own cold/warm response delivery.
        super.onNewIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        refreshProtection()
        val resumed = coordinator.resume()
        if (resumed != null) channel?.invokeMethod("credentialPromptResumed", mapOf("attemptId" to resumed))
        val request = pending
        if (request != null && coordinator.acceptHeldCredential()) finish(request, true)
    }

    override fun onPause() {
        val request = pending
        if (coordinator.pause()) {
            channel?.invokeMethod("credentialPromptPaused", mapOf("attemptId" to request!!.attempt.id))
        } else {
            channel?.invokeMethod("accessInvalidated", null)
            request?.let { finish(it, false) }
        }
        super.onPause()
    }

    override fun onUserLeaveHint() {
        invalidateAccess()
        super.onUserLeaveHint()
    }

    override fun onDestroy() {
        invalidateAccess()
        if (receiverRegistered) {
            unregisterReceiver(interruptionReceiver)
            receiverRegistered = false
        }
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    private fun invalidateAccess() {
        coordinator.invalidate()
        channel?.invokeMethod("accessInvalidated", null)
        pending?.let { finish(it, false) }
    }

    private fun refreshProtection() {
        val enabled = try {
            val preferences = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            NativeAppLockPolicy.isEnabled(preferences.all["flutter.app_lock_policy_v1"],
                preferences.all["flutter.biometric_lock_enabled"])
        } catch (_: Exception) { true }
        if (enabled) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun authenticate(arguments: Any?, result: MethodChannel.Result) {
        val attempt = coordinator.begin(arguments)
        if (attempt == null) {
            result.error("authentication_unavailable", "Invalid, busy, or nonforeground authentication request", null)
            return
        }
        val request = PendingAuthentication(attempt, result)
        pending = request
        try {
            val available = BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            if (available != BiometricManager.BIOMETRIC_SUCCESS) {
                launchCredential(request)
                return
            }
            val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                        if (pending === request && coordinator.challenge == null) finish(request, true)
                    }
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        if (pending !== request || coordinator.challenge != null) return
                        if (code == BiometricPrompt.ERROR_NEGATIVE_BUTTON) launchCredential(request)
                        else finish(request, false)
                    }
                })
            request.prompt = prompt
            prompt.authenticate(BiometricPrompt.PromptInfo.Builder()
                .setTitle(attempt.reason)
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
                .setNegativeButtonText(request.fallbackLabel)
                .build())
        } catch (_: Exception) {
            finish(request, false)
        }
    }

    @Suppress("DEPRECATION")
    private fun launchCredential(request: PendingAuthentication) {
        if (pending !== request || !coordinator.isCurrent(request.attempt) || !coordinator.foreground) {
            finish(request, false)
            return
        }
        try {
            val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            val intent = keyguard.createConfirmDeviceCredentialIntent(request.attempt.reason, null)
            if (intent == null) {
                finish(request, false)
                return
            }
            val challenge = coordinator.prepareCredential(request.attempt, UUID.randomUUID().toString())
            if (challenge == null) {
                finish(request, false)
                return
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NO_USER_ACTION)
            startActivityForResult(intent, challenge.requestCode)
        } catch (_: Exception) {
            finish(request, false)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val request = pending ?: return
        val challenge = coordinator.challenge ?: return
        if (challenge.requestCode != requestCode || challenge.request !== request.attempt) return
        when (coordinator.credentialResult(requestCode, resultCode == Activity.RESULT_OK)) {
            CredentialChallengeResultDisposition.ACCEPTED -> finish(request, true)
            CredentialChallengeResultDisposition.REJECTED -> finish(request, false)
            CredentialChallengeResultDisposition.HOLD_FOR_RESUME -> Unit
        }
    }

    private fun finish(request: PendingAuthentication, authenticated: Boolean) {
        if (pending !== request) return
        val response = coordinator.complete(request.attempt, authenticated)
            ?: mapOf("attemptId" to request.attempt.id, "authenticated" to false)
        pending = null
        request.prompt?.cancelAuthentication()
        request.prompt = null
        request.result.success(response)
    }
}
