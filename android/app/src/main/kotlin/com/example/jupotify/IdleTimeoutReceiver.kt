package com.example.jupotify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlin.system.exitProcess

class IdleTimeoutReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val prefs = context.getSharedPreferences("jupotify_idle", Context.MODE_PRIVATE)
            val isPlaying = prefs.getBoolean("is_playing", false)
            val scheduledAt = prefs.getLong("scheduled_at", 0L)
            val now = System.currentTimeMillis()

            // Only kill if still not playing and the alarm wasn't stale
            if (!isPlaying && now - scheduledAt >= 5 * 60 * 1000L - 5_000L) {
                Log.i("IdleTimeout", "Idle timeout reached. Terminating process.")
                // Best-effort termination
                android.os.Process.killProcess(android.os.Process.myPid())
                exitProcess(0)
            } else {
                Log.i("IdleTimeout", "Alarm received but playback active or stale; skipping kill.")
            }
        } catch (e: Exception) {
            Log.e("IdleTimeout", "Error handling idle timeout: ${e.message}")
        }
    }
}


