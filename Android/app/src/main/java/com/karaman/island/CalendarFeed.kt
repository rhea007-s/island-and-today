package com.karaman.island

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import java.time.Instant

/** The next timed event on the device calendars, for the "meeting soon" wings. */
object CalendarFeed {
    data class Event(val title: String, val start: Instant, val end: Instant, val location: String?)

    fun refresh(context: Context) {
        if (context.checkSelfPermission(Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
            IslandHub.nextEvent = null
            return
        }
        val now = System.currentTimeMillis()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            android.content.ContentUris.appendId(it, now - 60 * 60_000)
            android.content.ContentUris.appendId(it, now + 24 * 60 * 60_000)
        }.build()
        val cols = arrayOf(
            CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END, CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.ALL_DAY,
        )
        IslandHub.nextEvent = runCatching {
            context.contentResolver.query(uri, cols, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
                while (c.moveToNext()) {
                    if (c.getInt(4) == 1) continue
                    val end = c.getLong(2)
                    if (end < now) continue
                    return@use Event(
                        title = c.getString(0) ?: "Event",
                        start = Instant.ofEpochMilli(c.getLong(1)),
                        end = Instant.ofEpochMilli(end),
                        location = c.getString(3)?.ifBlank { null },
                    )
                }
                null
            }
        }.getOrNull()
    }

    /** An event starting within 10 minutes, or already under way. */
    fun soon(): Event? {
        val e = IslandHub.nextEvent ?: return null
        val now = Instant.now()
        return if (e.start.minusSeconds(600) <= now && now < e.end) e else null
    }
}
