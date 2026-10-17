package com.simpastil.simpastil_storage

import android.content.Context
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class SimpastilStoragePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPicker: MethodChannel.Result? = null
    private var pendingWritable = false
    private data class ChosenDocument(val uri: Uri, val writable: Boolean)
    private val documents = ConcurrentHashMap<String, ChosenDocument>()
    private val maximumDocumentBytes = 64 * 1024 * 1024 + 96
    private val documentRequestCode = 40962
    private class DocumentTooLarge : Exception()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "simpastil_storage")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method in listOf("chooseBackupDestination", "chooseBackupSource")) {
            chooseDocument(call, result)
            return
        }
        if (call.method !in listOf("noBackupPath", "syncDirectory", "availableBytes", "flushCredentialStorage",
                "writeBackupDocument", "readBackupDocument")) {
            result.notImplemented()
            return
        }
        worker.execute {
            try {
                val root = context.noBackupFilesDir.canonicalFile
                val value: Any? = when (call.method) {
                    "flushCredentialStorage" -> {
                        // flutter_secure_storage 9.2.4 uses apply() against this
                        // backing file, including EncryptedSharedPreferences.
                        // A checked synchronous commit waits all earlier writes.
                        // All current Flutter engines run in the same process.
                        check(context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
                            .edit().commit()) { "Credential persistence failed" }
                        null
                    }
                    "noBackupPath" -> root.path
                    "availableBytes" -> StatFs(root.path).availableBytes
                    "writeBackupDocument" -> {
                        val doc = chosenDocument(call)
                        require(doc.writable) { "Document was not chosen for writing" }
                        val bytes = call.argument<ByteArray>("bytes")
                            ?: throw IllegalArgumentException("Missing bytes")
                        require(bytes.size <= maximumDocumentBytes) { "Document too large" }
                        // Direct chosen-provider IO: no public path or private clear cache.
                        val stream = context.contentResolver.openOutputStream(doc.uri, "wt")
                            ?: throw IllegalStateException("Destination unavailable")
                        stream.use { it.write(bytes); it.flush() }
                        null
                    }
                    "readBackupDocument" -> {
                        val doc = chosenDocument(call)
                        val limit = call.argument<Int>("maximumBytes")
                            ?: throw IllegalArgumentException("Missing bound")
                        require(limit in 1..maximumDocumentBytes) { "Invalid read bound" }
                        val stream = context.contentResolver.openInputStream(doc.uri)
                            ?: throw IllegalStateException("Document unavailable")
                        stream.use {
                            val output = ByteArrayOutputStream()
                            val buffer = ByteArray(16384)
                            while (true) {
                                val read = it.read(buffer)
                                if (read < 0) break
                                if (output.size().toLong() + read > limit.toLong()) throw DocumentTooLarge()
                                output.write(buffer, 0, read)
                            }
                            output.toByteArray()
                        }
                    }
                    else -> {
                        val requested = call.argument<String>("path")
                            ?: throw IllegalArgumentException("Missing directory")
                        val dir = File(requested).canonicalFile
                        val legacy = File(context.applicationInfo.dataDir, "app_flutter").canonicalFile
                        require(listOf(root, legacy).any {
                            dir == it || dir.path.startsWith(it.path + File.separator)
                        }) {
                            "Directory is outside private care storage"
                        }
                        val fd = Os.open(dir.path, OsConstants.O_RDONLY, 0)
                        try {
                            require(OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) { "Not a directory" }
                            Os.fsync(fd)
                        } finally { Os.close(fd) }
                        null
                    }
                }
                main.post { result.success(value) }
            } catch (_: DocumentTooLarge) {
                main.post { result.error("backup_document_too_large", "Chosen document exceeds the supported bound", null) }
            } catch (_: Exception) {
                val backup = call.method in listOf("writeBackupDocument", "readBackupDocument")
                main.post { result.error(if (backup) "backup_document_unavailable" else "private_storage_unavailable",
                    if (backup) "Chosen document operation failed" else "Private storage operation failed", null) }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity(false)
        documents.clear()
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    private fun chosenDocument(call: MethodCall): ChosenDocument {
        val token = call.argument<String>("token") ?: throw IllegalArgumentException("Missing token")
        return documents[token] ?: throw IllegalArgumentException("Document was not chosen here")
    }

    private fun chooseDocument(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null || activity.isFinishing) {
            result.error("backup_picker_unavailable", "Open the app to choose a document", null)
            return
        }
        if (pendingPicker != null) {
            result.error("backup_picker_busy", "A document chooser is already open", null)
            return
        }
        val writable = call.method == "chooseBackupDestination"
        val intent = Intent(if (writable) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("application/octet-stream")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (writable) {
            intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            val name = call.argument<String>("name") ?: "Simpastil.simpbak"
            require(name.length <= 128) { "Invalid document name" }
            intent.putExtra(Intent.EXTRA_TITLE, name)
        }
        pendingPicker = result
        pendingWritable = writable
        try {
            activity.startActivityForResult(intent, documentRequestCode)
        } catch (_: Exception) {
            pendingPicker = null
            result.error("backup_picker_unavailable", "Document chooser unavailable", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != documentRequestCode) return false
        val result = pendingPicker ?: return true
        pendingPicker = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") {
            result.error("backup_document_unavailable", "Chosen document unavailable", null)
            return true
        }
        val writable = pendingWritable
        // Display-name queries can involve a remote provider; keep them off the UI thread.
        worker.execute {
            try {
                var name = "Simpastil.simpbak"
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0)?.take(512) ?: name
                }
                val token = UUID.randomUUID().toString()
                documents[token] = ChosenDocument(uri, writable)
                main.post { result.success(mapOf("token" to token, "displayName" to name)) }
            } catch (_: Exception) {
                main.post { result.error("backup_document_unavailable", "Chosen document unavailable", null) }
            }
        }
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    private fun detachActivity(configurationChange: Boolean) {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        if (!configurationChange) {
            pendingPicker?.error("backup_picker_unavailable", "Document chooser detached", null)
            pendingPicker = null
        }
    }
    override fun onDetachedFromActivityForConfigChanges() = detachActivity(true)
    override fun onDetachedFromActivity() = detachActivity(false)
}
