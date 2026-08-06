package com.bintangkecil.swf

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.URLUtil
import androidx.core.content.FileProvider
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.bintangkecil.swf/native"
    private var swipeRefreshLayout: SwipeRefreshLayout? = null
    private var methodChannel: MethodChannel? = null
    private var canChildScrollUp = false
    private val TAG = "MainActivity"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enablePullToRefresh" -> {
                    Log.d(TAG, "enablePullToRefresh called")
                    // Delay untuk memastikan view sudah ready
                    Handler(Looper.getMainLooper()).postDelayed({
                        enablePullToRefresh()
                    }, 500)
                    result.success(true)
                }
                "refreshComplete" -> {
                    Log.d(TAG, "refreshComplete called")
                    runOnUiThread {
                        swipeRefreshLayout?.isRefreshing = false
                    }
                    result.success(true)
                }
                "updateScrollState" -> {
                    val isAtTop = call.argument<Boolean>("isAtTop") ?: true
                    canChildScrollUp = !isAtTop
                    Log.d(TAG, "updateScrollState: isAtTop=$isAtTop, canChildScrollUp=$canChildScrollUp")
                    result.success(true)
                }
                "downloadUrl" -> {
                    val url = call.argument<String>("url")
                    val filename = call.argument<String>("filename") ?: ""
                    if (url.isNullOrBlank()) {
                        result.error("INVALID", "URL required", null)
                    } else {
                        downloadUrl(url, filename)
                        result.success(true)
                    }
                }
                "saveBase64File" -> {
                    val data = call.argument<String>("data")
                    val filename = call.argument<String>("filename") ?: "download.pdf"
                    if (data.isNullOrBlank()) {
                        result.error("INVALID", "Data required", null)
                    } else {
                        saveBase64File(data, filename)
                        result.success(true)
                    }
                }
                "sharePdfUrl" -> {
                    val url = call.argument<String>("url")
                    val filename = call.argument<String>("filename") ?: "document.pdf"
                    val target = call.argument<String>("target") ?: "whatsapp"
                    if (url.isNullOrBlank()) {
                        result.error("INVALID", "URL required", null)
                    } else {
                        sharePdfUrl(url, filename, target, result)
                    }
                }
                "shareBase64Pdf" -> {
                    val data = call.argument<String>("data")
                    val filename = call.argument<String>("filename") ?: "document.pdf"
                    val target = call.argument<String>("target") ?: "whatsapp"
                    if (data.isNullOrBlank()) {
                        result.error("INVALID", "Data required", null)
                    } else {
                        try {
                            val file = saveBytesToCache(data, filename)
                            shareFile(file, guessMimeType(filename), target)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Share base64 failed: ${e.message}", e)
                            result.error("SHARE_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enablePullToRefresh() {
        try {
            runOnUiThread {
                Log.d(TAG, "Attempting to enable pull-to-refresh")
                
                // Cari Flutter view
                val decorView = window.decorView
                val contentView = decorView.findViewById<ViewGroup>(android.R.id.content)
                
                if (contentView == null) {
                    Log.e(TAG, "Content view is null")
                    return@runOnUiThread
                }
                
                // Traverse untuk cari FlutterView
                var flutterView: ViewGroup? = null
                for (i in 0 until contentView.childCount) {
                    val child = contentView.getChildAt(i)
                    if (child is ViewGroup) {
                        flutterView = child
                        break
                    }
                }
                
                if (flutterView == null) {
                    Log.e(TAG, "Flutter view not found")
                    return@runOnUiThread
                }
                
                if (swipeRefreshLayout != null) {
                    Log.d(TAG, "SwipeRefreshLayout already exists")
                    return@runOnUiThread
                }
                
                Log.d(TAG, "Creating SwipeRefreshLayout")
                
                swipeRefreshLayout = SwipeRefreshLayout(this).apply {
                    setColorSchemeColors(0xFF0D9488.toInt())
                    setProgressBackgroundColorSchemeColor(0xFFFFFFFF.toInt())
                    
                    setOnChildScrollUpCallback { _, _ ->
                        canChildScrollUp
                    }
                    
                    setOnRefreshListener {
                        if (canChildScrollUp) {
                            Log.d(TAG, "Pull-to-refresh ignored: not at top")
                            isRefreshing = false
                            return@setOnRefreshListener
                        }
                        Log.d(TAG, "Pull-to-refresh triggered")
                        isRefreshing = true
                        methodChannel?.invokeMethod("onRefresh", null)
                    }
                }
                
                // Wrap FlutterView dengan SwipeRefreshLayout
                val parent = flutterView.parent as? ViewGroup
                if (parent != null) {
                    val index = parent.indexOfChild(flutterView)
                    val layoutParams = flutterView.layoutParams
                    
                    parent.removeView(flutterView)
                    swipeRefreshLayout?.layoutParams = layoutParams
                    swipeRefreshLayout?.addView(flutterView, ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    ))
                    parent.addView(swipeRefreshLayout, index)
                    
                    Log.d(TAG, "SwipeRefreshLayout successfully added")
                } else {
                    Log.e(TAG, "Parent view is null")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error enabling pull-to-refresh: ${e.message}", e)
        }
    }

    private fun downloadUrl(url: String, filename: String) {
        try {
            val safeName = filename.ifBlank { URLUtil.guessFileName(url, null, null) }
            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(safeName)
                .setDescription("SWF Download")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safeName)

            val cookies = CookieManager.getInstance().getCookie(url)
            if (!cookies.isNullOrEmpty()) {
                request.addRequestHeader("Cookie", cookies)
            }

            val dm = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
            dm.enqueue(request)
            Log.d(TAG, "Download enqueued: $url -> $safeName")
        } catch (e: Exception) {
            Log.e(TAG, "Download failed: ${e.message}", e)
            throw e
        }
    }

    private fun saveBase64File(base64: String, filename: String) {
        try {
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            val safeName = filename.ifBlank { "download.pdf" }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                    put(MediaStore.Downloads.MIME_TYPE, guessMimeType(safeName))
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                uri?.let {
                    contentResolver.openOutputStream(it)?.use { os -> os.write(bytes) }
                } ?: throw IllegalStateException("Failed to create download entry")
            } else {
                @Suppress("DEPRECATION")
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                java.io.File(dir, safeName).writeBytes(bytes)
            }
            Log.d(TAG, "File saved: $safeName")
        } catch (e: Exception) {
            Log.e(TAG, "Save failed: ${e.message}", e)
            throw e
        }
    }

    private fun guessMimeType(filename: String): String {
        return when {
            filename.endsWith(".pdf", ignoreCase = true) -> "application/pdf"
            filename.endsWith(".xlsx", ignoreCase = true) ->
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            filename.endsWith(".docx", ignoreCase = true) ->
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            else -> "application/octet-stream"
        }
    }

    private fun saveBytesToCache(base64: String, filename: String): File {
        val bytes = Base64.decode(base64, Base64.DEFAULT)
        val safeName = filename.ifBlank { "document.pdf" }
        val file = File(cacheDir, safeName)
        file.writeBytes(bytes)
        return file
    }

    private fun downloadToCache(url: String, filename: String): File {
        val safeName = filename.ifBlank { URLUtil.guessFileName(url, null, null) }
        val file = File(cacheDir, safeName)
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            val cookies = CookieManager.getInstance().getCookie(url)
            if (!cookies.isNullOrEmpty()) {
                setRequestProperty("Cookie", cookies)
            }
            connectTimeout = 30_000
            readTimeout = 60_000
            connect()
        }
        try {
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("HTTP ${connection.responseCode}")
            }
            connection.inputStream.use { input ->
                file.outputStream().use { output -> input.copyTo(output) }
            }
        } finally {
            connection.disconnect()
        }
        return file
    }

    private fun sharePdfUrl(
        url: String,
        filename: String,
        target: String,
        result: MethodChannel.Result
    ) {
        Thread {
            try {
                val file = downloadToCache(url, filename)
                runOnUiThread {
                    try {
                        shareFile(file, guessMimeType(filename), target)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Share file failed: ${e.message}", e)
                        result.error("SHARE_FAILED", e.message, null)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Download for share failed: ${e.message}", e)
                runOnUiThread {
                    result.error("SHARE_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun shareFile(file: File, mimeType: String, target: String) {
        val uri = FileProvider.getUriForFile(
            this,
            "${packageName}.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        if (target == "whatsapp") {
            for (pkg in listOf("com.whatsapp", "com.whatsapp.w4b")) {
                intent.setPackage(pkg)
                try {
                    startActivity(intent)
                    return
                } catch (_: ActivityNotFoundException) {
                }
            }
            intent.setPackage(null)
        }

        startActivity(Intent.createChooser(intent, "Bagikan PDF"))
    }

    override fun onDestroy() {
        super.onDestroy()
        methodChannel?.setMethodCallHandler(null)
    }
}
