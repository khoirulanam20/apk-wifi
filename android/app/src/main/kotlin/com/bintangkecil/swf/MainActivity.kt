package com.bintangkecil.swf

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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

    override fun onDestroy() {
        super.onDestroy()
        methodChannel?.setMethodCallHandler(null)
    }
}
