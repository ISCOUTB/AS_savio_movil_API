package com.example.arquisoft

import android.os.Build
import android.webkit.CookieManager
import android.webkit.ValueCallback
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val CHANNEL = "app/session"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				"clearCookies" -> {
					try {
						val cm = CookieManager.getInstance()
						if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
							cm.removeAllCookies { _ -> result.success(true) }
						} else {
							@Suppress("DEPRECATION")
							cm.removeAllCookie()
							result.success(true)
						}
						cm.flush()
					} catch (e: Exception) {
						result.error("COOKIE_ERROR", e.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}
}
