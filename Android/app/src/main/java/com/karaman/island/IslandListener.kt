package com.karaman.island

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.SystemClock
import android.provider.Settings as AndroidSettings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Android only lets a notification listener see other apps' media sessions,
 * so this one service feeds both the music wings and the notification banners.
 */
class IslandListener : NotificationListenerService() {

    private var sessions: MediaSessionManager? = null
    private var controller: MediaController? = null

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        pick(list.orEmpty())
    }

    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish()
        override fun onSessionDestroyed() {
            controller = null
            IslandHub.music = null
        }
    }

    override fun onListenerConnected() {
        IslandHub.listenerConnected = true
        Settings.load(this)
        val manager = getSystemService(MediaSessionManager::class.java)
        sessions = manager
        val me = ComponentName(this, IslandListener::class.java)
        runCatching {
            manager.addOnActiveSessionsChangedListener(sessionsChanged, me)
            pick(manager.getActiveSessions(me))
        }
        instance = this
    }

    override fun onListenerDisconnected() {
        IslandHub.listenerConnected = false
        sessions?.removeOnActiveSessionsChangedListener(sessionsChanged)
        controller?.unregisterCallback(callback)
        controller = null
        instance = null
    }

    /** The session that is playing beats one that is merely paused. */
    private fun pick(list: List<MediaController>) {
        val best = list.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list.firstOrNull()
        if (best?.sessionToken == controller?.sessionToken) return publish()
        controller?.unregisterCallback(callback)
        controller = best
        best?.registerCallback(callback)
        publish()
    }

    private fun publish() {
        val c = controller
        val meta = c?.metadata
        if (c == null || meta == null) {
            IslandHub.music = null
            return
        }
        val state = c.playbackState
        IslandHub.music = NowPlayingInfo(
            title = meta.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty(),
            artist = meta.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: meta.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST).orEmpty(),
            art = meta.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: meta.getBitmap(MediaMetadata.METADATA_KEY_ART),
            playing = state?.state == PlaybackState.STATE_PLAYING,
            durationMs = meta.getLong(MediaMetadata.METADATA_KEY_DURATION),
            positionMs = state?.position ?: 0,
            positionAt = state?.lastPositionUpdateTime ?: SystemClock.elapsedRealtime(),
            packageName = c.packageName,
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!Settings.showNotifications) return
        val n = sbn.notification
        if (sbn.packageName == packageName || sbn.packageName in Settings.muted) return
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        // Media players post a notification for every track; the wings already show it.
        if (n.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return
        if (n.category == Notification.CATEGORY_PROGRESS || n.category == Notification.CATEGORY_TRANSPORT) return
        // A silent update to a notification already shown is not news.
        if (n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0 && sbn.key in seen) return
        seen += sbn.key

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: appLabel(sbn.packageName)
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return

        val icon = runCatching {
            n.getLargeIcon()?.loadDrawable(this)?.toBitmap()
                ?: packageManager.getApplicationIcon(sbn.packageName).toBitmap()
        }.getOrNull()

        IslandHub.show(Banner(
            kind = Banner.Kind.Notification,
            title = title,
            text = text,
            icon = icon,
            packageName = sbn.packageName,
            tap = n.contentIntent,
        ), seconds = 5)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        seen -= sbn.key
    }

    private val seen = mutableSetOf<String>()

    private fun appLabel(pkg: String) = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    companion object {
        var instance: IslandListener? = null
            private set

        fun transport(): MediaController.TransportControls? = instance?.controller?.transportControls

        /**
         * The player's own "now playing" screen when it offers one (Spotify,
         * YouTube Music and most others do), otherwise just the app.
         */
        fun openPlayer(context: Context) {
            instance?.controller?.sessionActivity?.let { pending ->
                if (runCatching { pending.send() }.isSuccess) {
                    IslandHub.close()
                    return
                }
            }
            val pkg = IslandHub.music?.packageName ?: return
            context.packageManager.getLaunchIntentForPackage(pkg)?.let {
                it.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(it)
            }
        }

        fun isEnabled(context: Context): Boolean {
            val flat = AndroidSettings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty()
            return flat.contains(ComponentName(context, IslandListener::class.java).flattenToString())
        }
    }
}

fun Drawable.toBitmap(size: Int = 96): Bitmap {
    val w = if (intrinsicWidth > 0) intrinsicWidth.coerceAtMost(size) else size
    val h = if (intrinsicHeight > 0) intrinsicHeight.coerceAtMost(size) else size
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    setBounds(0, 0, w, h)
    draw(canvas)
    return bmp
}
