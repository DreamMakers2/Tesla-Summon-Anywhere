package com.summonanywhere

import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.Priority
import io.flutter.plugin.common.MethodChannel

/** Observes delivered fixes; injection or a last-known fix alone is never proof. */
internal class LocationObservations(
    private val manager: LocationManager,
    private val fused: FusedLocationProviderClient,
) {
    private val main = Handler(Looper.getMainLooper())
    private var listening = false
    private var starting = false
    private var keepObserving = false
    private var observationGeneration = 0L
    private var submissionNanos = 0L
    private var gpsFix: Location? = null
    private var fusedFix: Location? = null
    private val started = mutableListOf<(Boolean) -> Unit>()
    private val waiters = mutableListOf<Waiter>()

    private val gpsListener = object : LocationListener {
        override fun onLocationChanged(location: Location) = received(true, location)
        @Deprecated("Deprecated in Android")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }
    private val fusedListener = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.locations.forEach { received(false, it) }
        }
    }

    fun beginMocking(complete: (Boolean) -> Unit) {
        keepObserving = true
        ensureStarted(complete)
    }

    fun submitted(elapsedRealtimeNanos: Long) {
        submissionNanos = elapsedRealtimeNanos
    }

    fun endMocking() {
        keepObserving = false
        submissionNanos = 0L
        gpsFix = null
        fusedFix = null
        waiters.toList().forEach {
            finish(it, null, "GPS observation cancelled. Request a new fix after stopping.")
        }
        stopListening()
    }

    fun observe(
        gps: Boolean, timeoutMs: Long, minElapsedRealtimeNanos: Long?, sinceTimestampMs: Long?,
        result: MethodChannel.Result,
    ) {
        val requiredThreshold = if (keepObserving && submissionNanos > 0L) {
            submissionNanos
        } else SystemClock.elapsedRealtimeNanos()
        val threshold = maxOf(requiredThreshold, minElapsedRealtimeNanos ?: 0L)
        val existing = if (gps) gpsFix else fusedFix
        if (existing != null && existing.elapsedRealtimeNanos >= threshold &&
            (sinceTimestampMs == null || existing.time >= sinceTimestampMs)
        ) {
            result.success(snapshot(existing))
            return
        }
        val waiter = Waiter(gps, threshold, sinceTimestampMs, result)
        waiter.timeout = Runnable { finish(waiter, null, "No fresh location fix. Check location access and try outdoors.") }
        waiters.add(waiter)
        main.postDelayed(waiter.timeout, timeoutMs.coerceIn(1000L, 60000L))
        ensureStarted { ready ->
            if (!ready && waiters.contains(waiter)) {
                finish(waiter, null, "Could not observe location. Allow precise location access.")
            }
        }
    }

    private fun ensureStarted(complete: (Boolean) -> Unit) {
        if (listening) {
            complete(true)
            return
        }
        started.add(complete)
        if (starting) return
        starting = true
        val expectedGeneration = observationGeneration
        try {
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0L, 0f, gpsListener, Looper.getMainLooper())
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
                .setMinUpdateIntervalMillis(0L).build()
            fused.requestLocationUpdates(request, fusedListener, Looper.getMainLooper())
                .addOnCompleteListener { task ->
                    starting = false
                    val ready = task.isSuccessful && expectedGeneration == observationGeneration
                    listening = ready
                    if (!ready) stopListening()
                    val callbacks = started.toList()
                    started.clear()
                    callbacks.forEach { it(ready) }
                }
        } catch (_: Exception) {
            starting = false
            stopListening()
            val callbacks = started.toList()
            started.clear()
            callbacks.forEach { it(false) }
        }
    }

    private fun received(gps: Boolean, location: Location) {
        if (gps) gpsFix = Location(location) else fusedFix = Location(location)
        waiters.toList().filter {
            it.gps == gps && location.elapsedRealtimeNanos >= it.minimumNanos &&
                (it.sinceMs == null || location.time >= it.sinceMs)
        }.forEach { finish(it, location, null) }
    }

    private fun finish(waiter: Waiter, location: Location?, error: String?) {
        if (!waiters.remove(waiter)) return
        main.removeCallbacks(waiter.timeout)
        if (location != null) waiter.result.success(snapshot(location))
        else waiter.result.error("GPS_OBSERVATION_UNAVAILABLE", error, null)
        if (!keepObserving && waiters.isEmpty()) stopListening()
    }

    private fun stopListening() {
        observationGeneration++
        try { manager.removeUpdates(gpsListener) } catch (_: Exception) {}
        try { fused.removeLocationUpdates(fusedListener) } catch (_: Exception) {}
        listening = false
    }

    private fun snapshot(location: Location): Map<String, Any?> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy" to location.accuracy.toDouble(),
        "timestampMs" to location.time,
        "elapsedRealtimeNanos" to location.elapsedRealtimeNanos,
        "mocked" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) location.isMock
            else @Suppress("DEPRECATION") location.isFromMockProvider,
        "provider" to location.provider,
    )

    private class Waiter(
        val gps: Boolean, val minimumNanos: Long, val sinceMs: Long?, val result: MethodChannel.Result,
    ) {
        lateinit var timeout: Runnable
    }
}
