package com.simpastil.simpastil

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The Android side of the problem report: saving the finished text file to
 * Downloads, handing it to an email app, and saying how Android remembers the
 * previous run ending. It never reads app data; the report text is built, and
 * shown to the person, in Dart before anything reaches this class.
 */
class ReportChannel(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "saveToDownloads" -> saveToDownloads(call, result)
                "composeEmail" -> composeEmail(call, result)
                "lastExit" -> result.success(lastExit())
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            // Only the class name leaves this method: a message could carry a path.
            result.error("report_failed", error.javaClass.simpleName, null)
        }
    }

    private fun saveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("fileName")
        val content = call.argument<String>("content")
        if (name == null || content == null || !SAFE_FILE_NAME.matches(name)) {
            result.error("invalid_arguments", "Invalid report file", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Writing to the shared Downloads folder needs a storage permission
            // before Android 10; the app asks for none, so the person shares
            // the report instead.
            result.success(mapOf("status" to "unsupported"))
            return
        }
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "text/plain")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        if (uri == null) {
            result.error("report_failed", "InsertFailed", null)
            return
        }
        try {
            val stream = resolver.openOutputStream(uri) ?: throw java.io.IOException("OpenFailed")
            stream.use { it.write(content.toByteArray(Charsets.UTF_8)) }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        // Android adds " (1)" when the name is taken; tell the person the real one.
        val savedName = resolver.query(
            uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null } ?: name
        result.success(mapOf("status" to "saved", "name" to savedName))
    }

    private fun composeEmail(call: MethodCall, result: MethodChannel.Result) {
        val to = call.argument<String>("to")
        val subject = call.argument<String>("subject")
        val body = call.argument<String>("body")
        val title = call.argument<String>("title")
        val name = call.argument<String>("fileName")
        val content = call.argument<String>("content")
        if (to == null || subject == null || body == null || name == null || content == null ||
            !SAFE_ADDRESS.matches(to) || !SAFE_FILE_NAME.matches(name)
        ) {
            result.error("invalid_arguments", "Invalid email", null)
            return
        }
        // Keep only the file being sent; an older report never lingers in the cache.
        val directory = File(activity.cacheDir, "reports").apply { mkdirs() }
        directory.listFiles()?.forEach { it.delete() }
        val file = File(directory, name).apply { writeText(content, Charsets.UTF_8) }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.reportfiles", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "message/rfc822"
            putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivity(Intent.createChooser(send, title))
            result.success("opened")
        } catch (error: ActivityNotFoundException) {
            result.success("no_app")
        }
    }

    /** How Android recorded the end of the previous run, or null before Android 11. */
    private fun lastExit(): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val exit = manager.getHistoricalProcessExitReasons(activity.packageName, 0, 5)
            .firstOrNull { it.processName == activity.packageName } ?: return null
        return mapOf("reason" to reasonName(exit.reason), "timestamp" to exit.timestamp)
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash_native"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
        ApplicationExitInfo.REASON_UNKNOWN -> "unknown"
        else -> "other"
    }

    companion object {
        const val NAME = "com.simpastil/report"
        private val SAFE_FILE_NAME = Regex("^simpastil-report-[0-9]{8}-[0-9]{2}\\.txt$")
        private val SAFE_ADDRESS = Regex("^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\\.[A-Za-z]{2,24}$")
    }
}
