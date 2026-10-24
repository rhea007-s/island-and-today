package com.karaman.island

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Pomodoro: work, short break, repeat. Runs inside the overlay service's process. */
object FocusTimer {
    enum class Phase { Work, Break }

    var phase by mutableStateOf(Phase.Work)
        private set
    var running by mutableStateOf(false)
        private set
    var paused by mutableStateOf(false)
        private set
    /** Seconds left in the current phase. */
    var remaining by mutableLongStateOf(0L)
        private set
    var total by mutableLongStateOf(1L)
        private set
    var completedToday by mutableIntStateOf(0)
        private set
    var taskTitle by mutableStateOf<String?>(null)
        private set

    val isActive get() = running
    val progress get() = if (total == 0L) 0f else 1f - remaining.toFloat() / total

    private var job: Job? = null
    private var endsAt = 0L

    fun start(title: String? = null, p: Phase = Phase.Work) {
        phase = p
        taskTitle = title ?: taskTitle
        total = 60L * if (p == Phase.Work) Settings.focusMinutes else Settings.breakMinutes
        remaining = total
        running = true
        paused = false
        tick()
    }

    fun togglePause() {
        if (!running) return
        paused = !paused
        if (paused) job?.cancel() else tick()
    }

    fun stop() {
        job?.cancel()
        running = false
        paused = false
        taskTitle = null
    }

    fun skip() = finish()

    private fun tick() {
        job?.cancel()
        endsAt = System.currentTimeMillis() + remaining * 1000
        job = IslandHub.scope.launch {
            while (true) {
                remaining = ((endsAt - System.currentTimeMillis() + 999) / 1000).coerceAtLeast(0)
                if (remaining == 0L) {
                    finish()
                    break
                }
                delay(250)
            }
        }
    }

    private fun finish() {
        job?.cancel()
        val ended = phase
        if (ended == Phase.Work) completedToday++
        IslandHub.show(Banner(
            kind = Banner.Kind.Focus,
            title = if (ended == Phase.Work) "Focus done" else "Break over",
            text = if (ended == Phase.Work) "Take a ${Settings.breakMinutes}-minute break" else "Back to it",
        ), seconds = 6)
        Haptics.buzz(strong = true)
        start(p = if (ended == Phase.Work) Phase.Break else Phase.Work)
    }

    fun format(seconds: Long) = "%d:%02d".format(seconds / 60, seconds % 60)
}
