package com.example.jupotify

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val channelName = "com.example.jupotify/idle"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleIdleKill" -> {
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    scheduleIdleKill(isPlaying)
                    result.success(null)
                }
                "cancelIdleKill" -> {
                    cancelIdleKill()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun scheduleIdleKill(isPlaying: Boolean) {
        val ctx = this.applicationContext
        val prefs = ctx.getSharedPreferences("jupotify_idle", Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean("is_playing", isPlaying)
            .putLong("scheduled_at", System.currentTimeMillis())
            .apply()

        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(ctx, IdleTimeoutReceiver::class.java)
        val flags = PendingIntent.FLAG_CANCEL_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val pi = PendingIntent.getBroadcast(ctx, 1001, intent, flags)

        // 5 minutes from now (elapsed real time to survive device time changes)
        val triggerAt = SystemClock.elapsedRealtime() + 5 * 60 * 1000L

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
        } else {
            am.setExact(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
        }
    }

    private fun cancelIdleKill() {
        val ctx = this.applicationContext
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(ctx, IdleTimeoutReceiver::class.java)
        val flags = PendingIntent.FLAG_CANCEL_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val pi = PendingIntent.getBroadcast(ctx, 1001, intent, flags)
        am.cancel(pi)

        // Also mark as playing to avoid accidental kill if alarm still fires
        val prefs = ctx.getSharedPreferences("jupotify_idle", Context.MODE_PRIVATE)
        prefs.edit().putBoolean("is_playing", true).apply()
    }
}
