package com.summonanywhere

import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.location.Criteria
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/** One bridge shared by the activity and the foreground-service Flutter engines. */
object MockLocationHandler {
    private const val CHANNEL_NAME = "com.summonanywhere/mock_location"
    private const val CLEANUP_KEY = "needsCleanup"
    private val main = Handler(Looper.getMainLooper())
    private val operations = ArrayDeque<((() -> Unit) -> Unit)>()
    private lateinit var appContext: Context
    private lateinit var locationManager: LocationManager
    private lateinit var fused: FusedLocationProviderClient
    private lateinit var observations: LocationObservations
    private var initialized = false
    private var busy = false
    private var gpsActive = false
    private var fusedActive = false
    private var cleanupNeeded = false
    private var interruptedRecoveryPending = false
    private var generation = 0L
    private var sessionId: Long? = null
    private val retiredSessions = mutableSetOf<Long>()
    private var mockingBlocked = true
    private var allowedSessionId: Long? = null
    private var activity: Activity? = null

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        appContext = context.applicationContext
        locationManager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        fused = LocationServices.getFusedLocationProviderClient(appContext)
        observations = LocationObservations(locationManager, fused)
        cleanupNeeded = preferences().getBoolean(CLEANUP_KEY, false)
        interruptedRecoveryPending = cleanupNeeded
        // A process death must not make an unfinished mock session look idle.
        if (cleanupNeeded) enqueue { done -> cleanupSession { done() } }
    }

    fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result -> main.post { handle(call, result) } }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enableMockProvider" -> {
                val expectedGeneration = generation
                val requestedSession = call.argument<Number>("sessionId")?.toLong()
                enqueue { done ->
                    if (expectedGeneration != generation || !sessionAllowed(requestedSession)) {
                        cancelled(result)
                        done()
                    } else enable(requestedSession, expectedGeneration, result, done)
                }
            }
            "updateLocation" -> {
                val latitude = call.argument<Number>("latitude")?.toDouble()
                val longitude = call.argument<Number>("longitude")?.toDouble()
                val requestedSession = call.argument<Number>("sessionId")?.toLong()
                if (latitude == null || longitude == null || !latitude.isFinite() ||
                    !longitude.isFinite() || latitude !in -90.0..90.0 || longitude !in -180.0..180.0
                ) {
                    result.error("INVALID_ARGS", "A valid latitude and longitude are required.", null)
                    return
                }
                val expectedGeneration = generation
                enqueue { done ->
                    update(latitude, longitude, requestedSession, expectedGeneration, result, done)
                }
            }
            "disableMockProvider" -> {
                // Invalidate queued updates before an outstanding Google Task completes.
                generation++
                sessionId = null
                enqueue { done ->
                    cleanupSession { error ->
                        if (error == null) result.success(true)
                        else result.error("MOCK_CLEANUP_FAILED", error, null)
                        done()
                    }
                }
            }
            "retireSession" -> {
                val retiredSession = call.argument<Number>("sessionId")?.toLong()
                if (retiredSession == null) {
                    result.error("INVALID_ARGS", "A GPS session ID is required.", null)
                    return
                }
                // Stop must remain final even if the OS leaves the worker running.
                retiredSessions.add(retiredSession)
                generation++
                if (sessionId == retiredSession) sessionId = null
                result.success(true)
            }
            "blockMocking" -> {
                // A Stop with missing task data must still fence off a surviving worker.
                mockingBlocked = true
                allowedSessionId = null
                generation++
                result.success(true)
            }
            "allowSession" -> {
                val requestedSession = call.argument<Number>("sessionId")?.toLong()
                if (requestedSession == null) {
                    result.error("INVALID_ARGS", "A GPS session ID is required.", null)
                } else if (requestedSession in retiredSessions) {
                    cancelled(result)
                } else if (cleanupNeeded || interruptedRecoveryPending || gpsActive || fusedActive ||
                    busy || operations.isNotEmpty()
                ) {
                    result.error("MOCK_CLEANUP_PENDING", "Finish GPS cleanup before starting a new session.", null)
                } else {
                    generation++
                    allowedSessionId = requestedSession
                    mockingBlocked = false
                    result.success(true)
                }
            }
            "observeGps", "observeFused" -> observations.observe(
                gps = call.method == "observeGps",
                timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 10000L,
                minElapsedRealtimeNanos = call.argument<Number>("minElapsedRealtimeNanos")?.toLong(),
                sinceTimestampMs = call.argument<Number>("sinceTimestampMs")?.toLong(),
                result = result,
            )
            "mockStatus" -> result.success(mapOf(
                "active" to (gpsActive && fusedActive),
                "cleanupPending" to (cleanupNeeded && !(gpsActive && fusedActive)),
                "sessionId" to sessionId,
            ))
            "isEnabled" -> result.success(isMockLocationEnabled())
            "openDeveloperSettings" -> openSettings(
                Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS), result,
            )
            "openBatterySettings" -> openSettings(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:${appContext.packageName}")
                }, result,
            )
            else -> result.notImplemented()
        }
    }

    private fun enable(
        requestedSession: Long?, expectedGeneration: Long,
        result: MethodChannel.Result, done: () -> Unit,
    ) {
        if (!sessionAllowed(requestedSession)) {
            cancelled(result)
            done()
            return
        }
        if (gpsActive && fusedActive && requestedSession == sessionId) {
            result.success(true)
            done()
            return
        }
        if (cleanupNeeded) {
            result.error("MOCK_CLEANUP_PENDING", "Stop the previous GPS session before starting again.", null)
            done()
            return
        }
        if (!isMockLocationEnabled()) {
            result.error("MOCK_LOCATION_PERMISSION", "Select this app as the mock location app in Developer options.", null)
            done()
            return
        }
        if (!persistCleanup(true)) {
            result.error("MOCK_LOCATION_ERROR", "Could not save GPS recovery state. Retry starting GPS sync.", null)
            done()
            return
        }
        sessionId = requestedSession
        try {
            @Suppress("DEPRECATION")
            locationManager.addTestProvider(
                LocationManager.GPS_PROVIDER, false, false, false, false, true, true, true,
                Criteria.POWER_LOW, Criteria.ACCURACY_FINE,
            )
            gpsActive = true
            locationManager.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true)
        } catch (_: Exception) {
            failAndClean(result, "Could not enable Android mock GPS. Check location and mock-app permissions.", done)
            return
        }
        try {
            fused.setMockMode(true).addOnCompleteListener { task ->
                fusedActive = task.isSuccessful
                if (!task.isSuccessful || expectedGeneration != generation || !sessionAllowed(requestedSession)) {
                    failAndClean(result, if (expectedGeneration != generation || !sessionAllowed(requestedSession)) "GPS startup was cancelled."
                        else "Could not enable fused mock location. Check mock-app permissions.", done)
                } else observations.beginMocking { ready ->
                    if (!ready || expectedGeneration != generation || !sessionAllowed(requestedSession)) {
                        failAndClean(result, if (expectedGeneration != generation || !sessionAllowed(requestedSession)) "GPS startup was cancelled."
                            else "Could not observe Android location. Allow precise location access.", done)
                    } else {
                        result.success(true)
                        done()
                    }
                }
            }
        } catch (_: Exception) {
            failAndClean(result, "Could not enable fused mock location. Check mock-app permissions.", done)
        }
    }

    private fun update(
        latitude: Double, longitude: Double, requestedSession: Long?, expectedGeneration: Long,
        result: MethodChannel.Result, done: () -> Unit,
    ) {
        if (expectedGeneration != generation || !sessionAllowed(requestedSession) ||
            requestedSession != sessionId || !gpsActive || !fusedActive
        ) {
            cancelled(result)
            done()
            return
        }
        val location = Location(LocationManager.GPS_PROVIDER).apply {
            this.latitude = latitude
            this.longitude = longitude
            accuracy = 5f
            time = System.currentTimeMillis()
            elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) isMock = true
        }
        observations.submitted(location.elapsedRealtimeNanos)
        try {
            locationManager.setTestProviderLocation(LocationManager.GPS_PROVIDER, location)
        } catch (_: Exception) {
            failAndClean(result, "Android rejected the GPS update. Check location permissions.", done)
            return
        }
        try {
            fused.setMockLocation(location).addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    failAndClean(result, "Android rejected the fused GPS update. Retry GPS sync.", done)
                } else {
                    if (expectedGeneration != generation || !sessionAllowed(requestedSession)) {
                        cancelled(result)
                    } else result.success(true)
                    done()
                }
            }
        } catch (_: Exception) {
            failAndClean(result, "Android rejected the fused GPS update. Retry GPS sync.", done)
        }
    }

    private fun failAndClean(result: MethodChannel.Result, message: String, done: () -> Unit) {
        generation++
        sessionId = null
        cleanup { cleanupError ->
            result.error("MOCK_LOCATION_ERROR", cleanupError ?: message, null)
            done()
        }
    }

    private fun cleanupSession(complete: (String?) -> Unit) {
        cleanup { error ->
            if (error != null || !interruptedRecoveryPending) complete(error)
            else resetInterruptedFusedCache(complete)
        }
    }

    /** S24 can retain a fused mock cache after its mock client was force-stopped. */
    private fun resetInterruptedFusedCache(complete: (String?) -> Unit) {
        if (!persistCleanup(true)) {
            cleanupNeeded = true
            complete("Could not save phone location recovery state. Retry Stop.")
            return
        }
        fun leaveMockMode(entered: Boolean) {
            try {
                fused.setMockMode(false).addOnCompleteListener { task ->
                    if (task.isSuccessful) fusedActive = false
                    if (entered && task.isSuccessful && persistCleanup(false)) {
                        interruptedRecoveryPending = false
                        complete(null)
                    } else {
                        complete("Phone location recovery is incomplete. Retry Stop to restore real location.")
                    }
                }
            } catch (_: Exception) {
                complete("Phone location recovery is incomplete. Retry Stop to restore real location.")
            }
        }
        try {
            // Entering and exiting clears FLP caches; no coordinates are submitted.
            fused.setMockMode(true).addOnCompleteListener { task ->
                fusedActive = task.isSuccessful
                leaveMockMode(task.isSuccessful)
            }
        } catch (_: Exception) {
            // Always try to leave, including when entering failed synchronously.
            leaveMockMode(false)
        }
    }

    /** Always attempt both layers, including after a partially completed startup. */
    private fun cleanup(complete: (String?) -> Unit) {
        observations.endMocking()
        if (!cleanupNeeded && !gpsActive && !fusedActive) {
            complete(null)
            return
        }
        var gpsFailed = false
        try {
            locationManager.setTestProviderEnabled(LocationManager.GPS_PROVIDER, false)
        } catch (_: IllegalArgumentException) {
            // There is no GPS test replacement to disable.
        } catch (_: Exception) {
            // Removal may still succeed, so attempt it independently below.
        }
        try {
            locationManager.removeTestProvider(LocationManager.GPS_PROVIDER)
            gpsActive = false
        } catch (_: IllegalArgumentException) {
            gpsActive = false
        } catch (_: Exception) {
            gpsFailed = true
        }
        try {
            fused.setMockMode(false).addOnCompleteListener { task ->
                if (task.isSuccessful) fusedActive = false
                // Interrupted recovery still owns the following cache-reset step.
                // Keep its persisted marker until that final exit from mock mode succeeds.
                if (!gpsFailed && task.isSuccessful &&
                    (interruptedRecoveryPending || persistCleanup(false))
                ) {
                    complete(null)
                } else {
                    complete("GPS cleanup is not confirmed. Select this app as the mock location app and retry Stop.")
                }
            }
        } catch (_: Exception) {
            complete("GPS cleanup is not confirmed. Select this app as the mock location app and retry Stop.")
        }
    }

    private fun enqueue(operation: (() -> Unit) -> Unit) {
        operations.add(operation)
        runNext()
    }

    private fun runNext() {
        if (busy || operations.isEmpty()) return
        busy = true
        operations.removeFirst().invoke {
            busy = false
            runNext()
        }
    }

    private fun preferences() = appContext.getSharedPreferences("summon_mock_location", Context.MODE_PRIVATE)

    private fun persistCleanup(needed: Boolean): Boolean {
        if (!preferences().edit().putBoolean(CLEANUP_KEY, needed).commit()) return false
        cleanupNeeded = needed
        return true
    }

    private fun cancelled(result: MethodChannel.Result) {
        result.error("GPS_SESSION_STOPPED", "GPS session has stopped.", null)
    }

    private fun sessionAllowed(requestedSession: Long?): Boolean =
        !mockingBlocked && requestedSession != null && allowedSessionId != null &&
            requestedSession == allowedSessionId && requestedSession !in retiredSessions

    private fun openSettings(intent: Intent, result: MethodChannel.Result) {
        val host = activity
        if (host == null) {
            result.error("NO_ACTIVITY", "Open the app before opening Android settings.", null)
            return
        }
        try {
            host.startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.error("SETTINGS_UNAVAILABLE", "Could not open Android settings.", null)
        }
    }

    private fun isMockLocationEnabled(): Boolean = try {
        val appOps = appContext.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        @Suppress("DEPRECATION")
        appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_MOCK_LOCATION, android.os.Process.myUid(), appContext.packageName,
        ) == AppOpsManager.MODE_ALLOWED
    } catch (_: Exception) {
        false
    }
}
