package com.karaman.island

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.VibrationEffect
import android.os.Vibrator

/** What a tablet will tell an ordinary app about itself. CPU load is off limits since Android 8. */
object SystemStats {
    data class Snapshot(val ramUsed: Long, val ramTotal: Long, val diskUsed: Long, val diskTotal: Long)

    fun read(context: Context): Snapshot {
        val am = context.getSystemService(ActivityManager::class.java)
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val fs = StatFs(Environment.getDataDirectory().path)
        return Snapshot(
            ramUsed = mem.totalMem - mem.availMem,
            ramTotal = mem.totalMem,
            diskUsed = fs.totalBytes - fs.availableBytes,
            diskTotal = fs.totalBytes,
        )
    }

    val device: String get() = "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    fun gb(bytes: Long) = "%.1f GB".format(bytes / 1_073_741_824.0)
}

object Haptics {
    lateinit var vibrator: Vibrator

    fun buzz(strong: Boolean = false) {
        if (!Settings.haptics || !::vibrator.isInitialized || !vibrator.hasVibrator()) return
        vibrator.vibrate(
            if (strong) VibrationEffect.createWaveform(longArrayOf(0, 40, 60, 40), -1)
            else VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
        )
    }
}
