package com.karaman.island

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color

enum class IslandStyle(val title: String) { Apple("Apple"), Cartoon("Cartoon") }

/** User choices, kept in SharedPreferences and mirrored as Compose state. */
object Settings {
    private lateinit var prefs: SharedPreferences

    val accents = listOf(
        Color(0xFF7C6CFF), Color(0xFF0A84FF), Color(0xFF34C759),
        Color(0xFFFF9F0A), Color(0xFFFF375F), Color(0xFF64D2FF),
    )

    var style by mutableStateOf(IslandStyle.Apple)
    var accentIndex by mutableIntStateOf(0)
    /** Width of the resting pill, in dp. Tablets have no notch to match. */
    var pillWidth by mutableFloatStateOf(150f)
    var pillHeight by mutableFloatStateOf(34f)
    /**
     * Gap from the top edge, in dp. Android keeps the status bar above every
     * overlay for touches, so a pill inside it is visible but cannot be
     * tapped; the default puts it just below.
     */
    var topOffset by mutableFloatStateOf(30f)
    var showNotifications by mutableStateOf(true)
    var showCharging by mutableStateOf(true)
    var showMusicInCompact by mutableStateOf(true)
    var haptics by mutableStateOf(true)
    var focusMinutes by mutableIntStateOf(25)
    var breakMinutes by mutableIntStateOf(5)
    /** Packages whose notifications never reach the island. */
    var muted by mutableStateOf(setOf<String>())

    val accent: Color get() = accents[accentIndex.coerceIn(accents.indices)]

    fun load(context: Context) {
        if (::prefs.isInitialized) return
        prefs = context.getSharedPreferences("island", Context.MODE_PRIVATE)
        style = runCatching { IslandStyle.valueOf(prefs.getString("style", "Apple")!!) }.getOrDefault(IslandStyle.Apple)
        accentIndex = prefs.getInt("accent", 0)
        pillWidth = prefs.getFloat("pillWidth", 150f)
        pillHeight = prefs.getFloat("pillHeight", 34f)
        topOffset = prefs.getFloat("topOffset", statusBarDp(context) + 4f)
        showNotifications = prefs.getBoolean("notifications", true)
        showCharging = prefs.getBoolean("charging", true)
        showMusicInCompact = prefs.getBoolean("musicCompact", true)
        haptics = prefs.getBoolean("haptics", true)
        focusMinutes = prefs.getInt("focus", 25)
        breakMinutes = prefs.getInt("break", 5)
        muted = prefs.getStringSet("muted", emptySet())!!.toSet()
    }

    fun statusBarDp(context: Context): Float {
        val res = context.resources
        val id = res.getIdentifier("status_bar_height", "dimen", "android")
        val px = if (id > 0) res.getDimensionPixelSize(id) else 0
        return px / res.displayMetrics.density
    }

    fun save() {
        prefs.edit()
            .putString("style", style.name)
            .putInt("accent", accentIndex)
            .putFloat("pillWidth", pillWidth)
            .putFloat("pillHeight", pillHeight)
            .putFloat("topOffset", topOffset)
            .putBoolean("notifications", showNotifications)
            .putBoolean("charging", showCharging)
            .putBoolean("musicCompact", showMusicInCompact)
            .putBoolean("haptics", haptics)
            .putInt("focus", focusMinutes)
            .putInt("break", breakMinutes)
            .putStringSet("muted", muted)
            .apply()
    }
}
