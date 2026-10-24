package com.karaman.island

import android.app.PendingIntent
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The three shapes the island takes — same as the Mac. */
enum class IslandShape { Compact, Peek, Expanded }

enum class IslandTab(val title: String) { Today("Today"), Focus("Focus"), Music("Music"), Claude("Claude"), System("System") }

/** Something the island drops down to say on its own: a notification, the charger, a timer. */
data class Banner(
    val id: Long = System.nanoTime(),
    val kind: Kind,
    val title: String,
    val text: String = "",
    val icon: Bitmap? = null,
    val packageName: String? = null,
    val tap: PendingIntent? = null,
) {
    enum class Kind { Notification, Charging, Focus, Info }
}

data class NowPlayingInfo(
    val title: String,
    val artist: String,
    val art: Bitmap?,
    val playing: Boolean,
    val durationMs: Long,
    val positionMs: Long,
    val positionAt: Long,
    val packageName: String,
)

/** The Mac's Claude Code usage, as it last published it to Firestore. */
data class ClaudeStatus(
    val dayTokens: Long,
    val dayOutput: Long,
    val dayReplies: Long,
    val sessionTokens: Long,
    val sessionReplies: Long,
    val sessionStart: java.time.Instant?,
    val sessionEnd: java.time.Instant?,
    val model: String,
    val updatedAt: java.time.Instant?,
)

/**
 * Everything the island renders, in one place. Listeners and timers write
 * here; the overlay reads it through Compose state, so a change anywhere
 * redraws the island without wiring.
 */
object IslandHub {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var shape by mutableStateOf(IslandShape.Compact)
    var tab by mutableStateOf(IslandTab.Today)
    var banner by mutableStateOf<Banner?>(null)
        private set
    var music by mutableStateOf<NowPlayingInfo?>(null)
    var battery by mutableStateOf(100)
    var charging by mutableStateOf(false)
    val tasks = mutableStateListOf<Task>()
    var nextEvent by mutableStateOf<CalendarFeed.Event?>(null)
    var listenerConnected by mutableStateOf(false)
    var claude by mutableStateOf<ClaudeStatus?>(null)

    private var bannerJob: Job? = null

    fun show(b: Banner, seconds: Long = 4) {
        banner = b
        bannerJob?.cancel()
        bannerJob = scope.launch {
            delay(seconds * 1000)
            if (banner?.id == b.id) banner = null
        }
    }

    fun dismissBanner() {
        bannerJob?.cancel()
        banner = null
    }

    fun open(t: IslandTab? = null) {
        if (t != null) tab = t
        shape = IslandShape.Expanded
    }

    fun close() { shape = IslandShape.Compact }
}
