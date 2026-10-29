package com.summonanywhere

import android.app.Application
import android.content.Context
import android.location.LocationManager
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

class SummonApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MockLocationHandler.init(this)
        cleanupLegacySyntheticProvider()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(
            object : FlutterForegroundTaskLifecycleListener {
                override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                    flutterEngine?.let { MockLocationHandler.register(it) }
                }

                override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

                override fun onTaskRepeatEvent() {}

                override fun onTaskDestroy() {}

                override fun onEngineWillDestroy() {}
            },
        )
    }

    // Previous versions used a separate synthetic test provider. Recover any
    // interrupted test once, without retaining its diagnostic interface.
    private fun cleanupLegacySyntheticProvider() {
        val prefs = getSharedPreferences("gps_diagnostics", Context.MODE_PRIVATE)
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = "summon_synthetic_diagnostics"
        try {
            if (manager.allProviders.contains(provider)) manager.removeTestProvider(provider)
            prefs.edit().putBoolean("active", false).commit()
        } catch (_: Exception) {
            prefs.edit().putBoolean("active", true).commit()
        }
    }
}
