package com.summonanywhere

import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object NotificationDiagnosticsHandler {
    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.summonanywhere/notifications")
            .setMethodCallHandler { call, result ->
                if (call.method != "openSettings") {
                    result.notImplemented()
                } else {
                    try {
                        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("settings_unavailable", "Notification settings could not be opened.", null)
                    }
                }
            }
    }
}
