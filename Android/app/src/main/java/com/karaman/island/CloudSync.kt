package com.karaman.island

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.Instant

/**
 * Kotlin twin of Shared/CloudSync.swift: Firestore over REST, same layout
 * (`users/{uid}/tasks/{id}` = json, updatedAt, deleted, syncedAt), so the
 * tablet, the iPhone and the Mac all see one list.
 */
object CloudSync {
    private const val PROJECT = "notch-beda7"
    /** From Android/local.properties (git-ignored): ISLAND_FIREBASE_KEY=… */
    private val KEY = BuildConfig.FIREBASE_KEY
    private const val ROOT = "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents"

    sealed interface Status {
        data object SignedOut : Status
        data object Idle : Status
        data object Syncing : Status
        data class Failed(val message: String) : Status
    }

    var status by mutableStateOf<Status>(Status.SignedOut)
        private set
    var email by mutableStateOf<String?>(null)
        private set
    var lastSync by mutableStateOf<Instant?>(null)
        private set

    private lateinit var prefs: SharedPreferences
    private lateinit var stateFile: File
    private var idToken: String? = null
    private var idTokenExpiry = Instant.EPOCH
    private var pending: Job? = null
    private var poller: Job? = null

    fun load(context: Context) {
        if (::prefs.isInitialized) return
        prefs = context.getSharedPreferences("session", Context.MODE_PRIVATE)
        stateFile = File(context.filesDir, "sync-state.json")
        email = prefs.getString("email", null)
        status = if (prefs.getString("refresh", null) == null) Status.SignedOut else Status.Idle
    }

    val isSignedIn get() = ::prefs.isInitialized && prefs.getString("refresh", null) != null

    fun startPolling(seconds: Long = 60) {
        sync()
        if (poller != null) return
        poller = IslandHub.scope.launch {
            while (isActive) {
                delay(seconds * 1000)
                sync()
            }
        }
    }

    fun localChanged() {
        if (!isSignedIn) return
        pending?.cancel()
        pending = IslandHub.scope.launch {
            delay(1500)
            sync()
        }
    }

    suspend fun signIn(email: String, password: String, create: Boolean) {
        status = Status.Syncing
        try {
            val endpoint = if (create) "accounts:signUp" else "accounts:signInWithPassword"
            val reply = http(
                "https://identitytoolkit.googleapis.com/v1/$endpoint?key=$KEY", "POST", null,
                JSONObject().put("email", email).put("password", password).put("returnSecureToken", true).toString(),
            ) as JSONObject
            prefs.edit()
                .putString("uid", reply.getString("localId"))
                .putString("email", reply.optString("email", email))
                .putString("refresh", reply.getString("refreshToken"))
                .apply()
            this.email = reply.optString("email", email)
            idToken = reply.getString("idToken")
            idTokenExpiry = Instant.now().plusSeconds(reply.optString("expiresIn", "3600").toLong() - 120)
            stateFile.delete()
            status = Status.Idle
            run()
        } catch (e: Exception) {
            status = Status.Failed(describe(e))
        }
    }

    fun signOut() {
        prefs.edit().clear().apply()
        stateFile.delete()
        idToken = null
        email = null
        status = Status.SignedOut
    }

    fun sync() {
        if (!isSignedIn || status == Status.Syncing) return
        IslandHub.scope.launch { run() }
    }

    private suspend fun run() {
        val uid = prefs.getString("uid", null) ?: return
        status = Status.Syncing
        try {
            val token = validToken()
            val state = loadState()
            pull(uid, token, state)
            push(uid, token, state)
            pullClaude(uid, token)
            saveState(state)
            lastSync = Instant.now()
            status = Status.Idle
        } catch (e: Exception) {
            status = Status.Failed(describe(e))
        }
    }

    private suspend fun pull(uid: String, token: String, state: JSONObject) {
        val query = JSONObject().put("from", JSONArray().put(JSONObject().put("collectionId", "tasks")))
        state.optString("cursor").takeIf { it.isNotEmpty() }?.let { cursor ->
            query.put("where", JSONObject().put("fieldFilter", JSONObject()
                .put("field", JSONObject().put("fieldPath", "syncedAt"))
                .put("op", "GREATER_THAN_OR_EQUAL")
                .put("value", JSONObject().put("timestampValue", cursor))))
        }
        val rows = http("$ROOT/users/$uid:runQuery", "POST", token,
            JSONObject().put("structuredQuery", query).toString()) as? JSONArray ?: JSONArray()

        val known = state.optJSONObject("known") ?: JSONObject().also { state.put("known", it) }
        var newest = Iso.parse(state.optString("cursor"))
        val upserts = mutableListOf<JSONObject>()
        val deletions = mutableMapOf<String, Instant>()
        for (i in 0 until rows.length()) {
            val doc = rows.getJSONObject(i).optJSONObject("document") ?: continue
            val fields = doc.optJSONObject("fields") ?: continue
            val id = doc.getString("name").substringAfterLast('/')
            ts(fields, "syncedAt")?.let { if (newest == null || it > newest) newest = it }
            val updated = ts(fields, "updatedAt") ?: Instant.EPOCH
            known.put(id, updated.epochSecond.toDouble())
            if (fields.optJSONObject("deleted")?.optBoolean("booleanValue") == true) {
                deletions[id] = updated
            } else {
                val raw = fields.optJSONObject("json")?.optString("stringValue").orEmpty()
                runCatching { JSONObject(raw) }.getOrNull()?.let(upserts::add)
            }
        }
        newest?.let { state.put("cursor", it.toString()) }
        if (upserts.isNotEmpty() || deletions.isNotEmpty()) TaskStore.applyRemote(upserts, deletions)
    }

    /** The Mac writes `status/claude`; missing until the Mac island has synced once. */
    private suspend fun pullClaude(uid: String, token: String) {
        val doc = try {
            http("$ROOT/users/$uid/status/claude", "GET", token, null) as JSONObject
        } catch (e: SyncError) {
            return
        }
        val f = doc.optJSONObject("fields") ?: return
        fun n(k: String) = f.optJSONObject(k)?.optString("integerValue")?.toLongOrNull() ?: 0L
        IslandHub.claude = ClaudeStatus(
            dayTokens = n("dayTokens"),
            dayOutput = n("dayOutput"),
            dayReplies = n("dayReplies"),
            sessionTokens = n("sessionTokens"),
            sessionReplies = n("sessionReplies"),
            sessionStart = ts(f, "sessionStart"),
            sessionEnd = ts(f, "sessionEnd"),
            model = f.optJSONObject("model")?.optString("stringValue").orEmpty(),
            updatedAt = ts(f, "updatedAt"),
        )
    }

    private suspend fun push(uid: String, token: String, state: JSONObject) {
        val known = state.optJSONObject("known") ?: JSONObject().also { state.put("known", it) }
        val writes = JSONArray()
        val sent = mutableMapOf<String, Double>()
        for (task in TaskStore.read()) {
            val stamp = task.updatedAt.epochSecond.toDouble()
            if (known.has(task.id) && known.getDouble(task.id) >= stamp) continue
            writes.put(write(uid, task.id, task.json.toString(), task.updatedAt, false))
            sent[task.id] = stamp
        }
        val deletes = state.optJSONArray("pendingDeletes") ?: JSONArray()
        val now = Instant.now()
        for (i in 0 until deletes.length()) {
            val id = deletes.getString(i)
            writes.put(write(uid, id, "", now, true))
            sent[id] = now.epochSecond.toDouble()
        }
        if (writes.length() == 0) return
        var start = 0
        while (start < writes.length()) {
            val chunk = JSONArray()
            for (i in start until minOf(start + 400, writes.length())) chunk.put(writes.get(i))
            http("$ROOT:commit", "POST", token, JSONObject().put("writes", chunk).toString())
            start += 400
        }
        sent.forEach { (k, v) -> known.put(k, v) }
        state.put("pendingDeletes", JSONArray())
    }

    private fun write(uid: String, id: String, json: String, updatedAt: Instant, deleted: Boolean) = JSONObject()
        .put("update", JSONObject()
            .put("name", "projects/$PROJECT/databases/(default)/documents/users/$uid/tasks/$id")
            .put("fields", JSONObject()
                .put("json", JSONObject().put("stringValue", json))
                .put("updatedAt", JSONObject().put("timestampValue", updatedAt.toString()))
                .put("deleted", JSONObject().put("booleanValue", deleted))))
        .put("updateTransforms", JSONArray().put(JSONObject()
            .put("fieldPath", "syncedAt").put("setToServerValue", "REQUEST_TIME")))

    private fun ts(fields: JSONObject, key: String): Instant? =
        Iso.parse(fields.optJSONObject(key)?.optString("timestampValue"))

    private suspend fun validToken(): String {
        idToken?.let { if (Instant.now() < idTokenExpiry) return it }
        val refresh = prefs.getString("refresh", null) ?: throw SyncError("Not signed in.")
        val reply = try {
            http("https://securetoken.googleapis.com/v1/token?key=$KEY", "POST", null,
                "grant_type=refresh_token&refresh_token=" + URLEncoder.encode(refresh, "UTF-8"),
                form = true) as JSONObject
        } catch (e: SyncError) {
            signOut()
            throw SyncError("Signed out — please sign in again.")
        }
        reply.optString("refresh_token").takeIf { it.isNotEmpty() && it != refresh }?.let {
            prefs.edit().putString("refresh", it).apply()
        }
        idToken = reply.getString("id_token")
        idTokenExpiry = Instant.now().plusSeconds(reply.optString("expires_in", "3600").toLong() - 120)
        return idToken!!
    }

    // Deletions made while offline or signed out wait here for the next push.
    fun enqueueDeletion(ids: Set<String>) {
        if (!::stateFile.isInitialized) return
        val state = loadState()
        val arr = state.optJSONArray("pendingDeletes") ?: JSONArray()
        ids.forEach { arr.put(it) }
        state.put("pendingDeletes", arr)
        saveState(state)
    }

    private fun loadState(): JSONObject = runCatching { JSONObject(stateFile.readText()) }.getOrDefault(JSONObject())
    private fun saveState(s: JSONObject) = stateFile.writeText(s.toString())

    class SyncError(message: String) : Exception(message)

    private suspend fun http(url: String, method: String, token: String?, body: String?, form: Boolean = false): Any =
        withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            c.requestMethod = method
            c.connectTimeout = 20_000
            c.readTimeout = 20_000
            c.setRequestProperty("Content-Type", if (form) "application/x-www-form-urlencoded" else "application/json")
            token?.let { c.setRequestProperty("Authorization", "Bearer $it") }
            if (body != null) {
                c.doOutput = true
                c.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = c.responseCode
            val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText().orEmpty()
            val json: Any = runCatching {
                if (text.trimStart().startsWith("[")) JSONArray(text) else JSONObject(text)
            }.getOrDefault(JSONObject())
            if (code !in 200..299) {
                val first = (json as? JSONArray)?.optJSONObject(0) ?: json as? JSONObject
                throw SyncError(first?.optJSONObject("error")?.optString("message") ?: "HTTP $code")
            }
            json
        }

    private fun describe(e: Exception): String {
        val raw = e.message ?: e.javaClass.simpleName
        return when {
            raw.startsWith("INVALID_LOGIN_CREDENTIALS") || raw.startsWith("INVALID_PASSWORD") ||
                raw.startsWith("EMAIL_NOT_FOUND") -> "Wrong email or password."
            raw.startsWith("EMAIL_EXISTS") -> "That email already has an account — sign in instead."
            raw.startsWith("WEAK_PASSWORD") -> "Password needs at least 6 characters."
            raw.startsWith("INVALID_EMAIL") -> "That email does not look right."
            raw.startsWith("TOO_MANY_ATTEMPTS") -> "Too many tries — wait a minute."
            else -> raw
        }
    }
}
