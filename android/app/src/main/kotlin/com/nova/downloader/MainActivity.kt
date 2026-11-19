package com.nova.downloader

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Host side of the "nova_downloader/files" channel.
 *
 * Android 10+ scoped storage blocks a direct write to the public Downloads
 * folder, so the finished temp file is moved in here via MediaStore
 * (RELATIVE_PATH = Download/). No file bytes cross the channel — only paths.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "nova_downloader/files"

    /** The channel to Dart, once the engine is configured. */
    private var filesChannel: MethodChannel? = null

    /** A shared link that arrived before the engine was ready. */
    private var pendingSharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        )
        filesChannel = channel
        channel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToDownloads" -> {
                        val tempPath = call.argument<String>("tempPath")
                        val displayName = call.argument<String>("displayName")
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        if (tempPath == null || displayName == null) {
                            result.error("BAD_ARGS", "tempPath/displayName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(moveToDownloads(tempPath, displayName, mimeType))
                        } catch (e: Exception) {
                            result.error("MOVE_FAILED", e.message, null)
                        }
                    }
                    "openFile" -> {
                        val location = call.argument<String>("location") ?: ""
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        result.success(openFile(location, mimeType))
                    }
                    "shareFile" -> {
                        val location = call.argument<String>("location") ?: ""
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        result.success(shareFile(location, mimeType))
                    }
                    "deleteFile" -> {
                        val location = call.argument<String>("location") ?: ""
                        result.success(deleteDownloadFile(location))
                    }
                    else -> result.notImplemented()
                }
            }
        // A link shared while the app was cold arrives with the launch
        // intent; one shared while the app is running arrives later via
        // onNewIntent (launchMode is singleTop).
        pendingSharedText?.let { text ->
            channel.invokeMethod("sharedLink", text)
            pendingSharedText = null
        }
        handleSharedIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSharedIntent(intent)
    }

    /**
     * "Share -> NOVA Downloader" from another app (ACTION_SEND, text/plain).
     * Forwards Intent.EXTRA_TEXT to Dart as 'sharedLink', which prefills
     * the link field on the Home tab. Links arriving before the engine is
     * ready are stashed and flushed in configureFlutterEngine.
     */
    private fun handleSharedIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        if (intent.type?.startsWith("text/") != true) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        if (text.isNullOrEmpty()) return
        val channel = filesChannel
        if (channel != null) {
            channel.invokeMethod("sharedLink", text)
        } else {
            pendingSharedText = text
        }
    }

    private fun moveToDownloads(tempPath: String, displayName: String, mimeType: String): String? {
        val src = File(tempPath)
        if (!src.exists()) return null
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Downloads.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Files.getContentUri("external")
        }
        val uri = contentResolver.insert(collection, values) ?: return null
        try {
            contentResolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { input -> input.copyTo(out) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val done = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                contentResolver.update(uri, done, null, null)
            }
            src.delete()
            return uri.toString()
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null)
            throw e
        }
    }

    private fun uriFor(location: String): Uri {
        return if (location.startsWith("content://")) {
            Uri.parse(location)
        } else {
            val file = File(location)
            FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file,
            )
        }
    }

    private fun openFile(location: String, mimeType: String): Boolean {
        return try {
            val uri = uriFor(location)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Open with"))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun shareFile(location: String, mimeType: String): Boolean {
        return try {
            val uri = uriFor(location)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share file"))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun deleteDownloadFile(location: String): Boolean {
        return try {
            if (location.startsWith("content://")) {
                contentResolver.delete(Uri.parse(location), null, null) > 0
            } else {
                File(location).delete()
            }
        } catch (e: Exception) {
            false
        }
    }
}
