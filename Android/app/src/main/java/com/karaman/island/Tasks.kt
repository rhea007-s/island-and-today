package com.karaman.island

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * One task, kept as the exact JSON the iPhone and Mac write, so fields this
 * app does not know about (schedule, calendarEventID, …) survive a round trip.
 */
class Task(val json: JSONObject) {
    val id: String get() = json.getString("id")
    val title: String get() = json.optString("title")
    val isDone: Boolean get() = json.optBoolean("isDone")
    val dayKey: String get() = json.optString("dayKey")
    val parentID: String? get() = json.optString("parentID").ifEmpty { null }
    val createdAt: Instant get() = Iso.parse(json.optString("createdAt")) ?: Instant.EPOCH
    val updatedAt: Instant get() = Iso.parse(json.optString("updatedAt")) ?: createdAt
    val scheduleStart: Instant? get() = json.optJSONObject("schedule")?.let { Iso.parse(it.optString("start")) }
}

/** Swift's `.iso8601` coding: UTC, whole seconds, no fraction — it rejects fractions. */
object Iso {
    fun format(i: Instant): String = i.truncatedTo(ChronoUnit.SECONDS).toString()
    fun parse(s: String?): Instant? = if (s.isNullOrEmpty()) null else runCatching { Instant.parse(s) }.getOrNull()
}

object DayKey {
    fun today(): String = LocalDate.now(ZoneId.systemDefault()).toString()
}

/** tasks.json in app storage — the same flat list the Apple apps keep. */
object TaskStore {
    private lateinit var file: File
    private val all = mutableListOf<Task>()

    fun load(context: Context) {
        if (::file.isInitialized) return
        file = File(context.filesDir, "tasks.json")
        all.clear()
        runCatching {
            val arr = JSONArray(file.readText())
            for (i in 0 until arr.length()) all += Task(arr.getJSONObject(i))
        }
        publish()
    }

    fun read(): List<Task> = all.toList()

    private fun save() {
        val arr = JSONArray()
        all.forEach { arr.put(it.json) }
        file.writeText(arr.toString())
        publish()
        CloudSync.localChanged()
    }

    /** Today's tasks, roots first then their children, oldest first — the order the Mac shows. */
    private fun publish() {
        val today = all.filter { it.dayKey == DayKey.today() }.sortedBy { it.createdAt }
        val ordered = buildList {
            today.filter { it.parentID == null }.forEach { root ->
                add(root)
                addAll(today.filter { it.parentID == root.id })
            }
        }
        IslandHub.tasks.clear()
        IslandHub.tasks.addAll(ordered)
    }

    fun add(title: String) {
        val text = title.trim()
        if (text.isEmpty()) return
        val now = Iso.format(Instant.now())
        all += Task(JSONObject().apply {
            put("id", UUID.randomUUID().toString().uppercase())
            put("title", text)
            put("isDone", false)
            put("createdAt", now)
            put("updatedAt", now)
            put("dayKey", DayKey.today())
        })
        save()
    }

    fun toggle(id: String) {
        val task = all.firstOrNull { it.id == id } ?: return
        val done = !task.isDone
        val now = Instant.now()
        // Ticking a parent ticks everything under it, like the Apple apps.
        val ids = setOf(id) + all.filter { it.parentID == id }.map { it.id }
        all.filter { it.id in ids }.forEach {
            it.json.put("isDone", done)
            if (done) it.json.put("completedAt", Iso.format(now)) else it.json.remove("completedAt")
            it.json.put("updatedAt", Iso.format(now))
        }
        save()
    }

    fun delete(id: String) {
        val ids = setOf(id) + all.filter { it.parentID == id }.map { it.id }
        all.removeAll { it.id in ids }
        CloudSync.enqueueDeletion(ids)
        save()
    }

    /** Newest `updatedAt` wins; tombstones remove unless the local copy is newer. */
    fun applyRemote(upserts: List<JSONObject>, deletions: Map<String, Instant>) {
        for (json in upserts) {
            val incoming = Task(json)
            val i = all.indexOfFirst { it.id == incoming.id }
            when {
                i < 0 -> all += incoming
                incoming.updatedAt >= all[i].updatedAt -> all[i] = incoming
            }
        }
        all.removeAll { t -> deletions[t.id]?.let { it >= t.updatedAt } == true }
        val arr = JSONArray()
        all.forEach { arr.put(it.json) }
        file.writeText(arr.toString())
        publish()
    }

    /** Called at midnight so the list shows the new day. */
    fun refreshDay() = publish()
}
