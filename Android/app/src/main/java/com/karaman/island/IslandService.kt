package com.karaman.island

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.Vibrator
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.time.LocalDate

/**
 * Keeps the island on screen above every app: a foreground service that owns
 * one overlay window at the top centre. The window wraps the island exactly,
 * so touches anywhere else go straight to the app underneath.
 */
class IslandService : Service(), LifecycleOwner, SavedStateRegistryOwner, ViewModelStoreOwner {

    private val lifecycleRegistry = LifecycleRegistry(this)
    private val savedState = SavedStateRegistryController.create(this)
    private val store = ViewModelStore()
    override val lifecycle: Lifecycle get() = lifecycleRegistry
    override val savedStateRegistry: SavedStateRegistry get() = savedState.savedStateRegistry
    override val viewModelStore: ViewModelStore get() = store

    private lateinit var wm: WindowManager
    private var root: FrameLayout? = null
    private lateinit var params: WindowManager.LayoutParams
    private var watcher: Job? = null
    private var day = LocalDate.now()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        savedState.performRestore(null)
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
        Settings.load(this)
        TaskStore.load(this)
        CloudSync.load(this)
        Haptics.vibrator = getSystemService(Vibrator::class.java)
        running = true

        goForeground()
        addOverlay()
        registerReceiver(power, IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_TIME_TICK)
            addAction(Intent.ACTION_SCREEN_OFF)
        })
        CalendarFeed.refresh(this)
        CloudSync.startPolling()
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopSelf()
            ACTION_OPEN -> IslandHub.open()
            // `adb shell am start -a com.karaman.island.DEMO -n com.karaman.island/.MainActivity`
            // fills sample Claude usage so the tab can be checked without an account.
            ACTION_DEMO -> {
                val now = java.time.Instant.now()
                val start = now.truncatedTo(java.time.temporal.ChronoUnit.HOURS)
                IslandHub.claude = ClaudeStatus(46_900_000, 232_000, 192, 921_000, 41, start,
                    start.plusSeconds(5 * 3600), "opus-5-5", now)
                IslandHub.open(IslandTab.Claude)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        watcher?.cancel()
        runCatching { unregisterReceiver(power) }
        root?.let { runCatching { wm.removeView(it) } }
        root = null
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        store.clear()
        super.onDestroy()
    }

    private fun addOverlay() {
        wm = getSystemService(WindowManager::class.java)
        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            BASE_FLAGS or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            title = "Island"
        }

        val compose = ComposeView(this).apply { setContent { Island() } }
        val frame = object : FrameLayout(this) {
            // A tap anywhere outside the island closes it, like on iPhone.
            override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
                if (ev.action == MotionEvent.ACTION_OUTSIDE) {
                    if (IslandHub.shape != IslandShape.Compact) IslandHub.close()
                    return false
                }
                return super.dispatchTouchEvent(ev)
            }

            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                    IslandHub.close()
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }
        frame.setViewTreeLifecycleOwner(this)
        frame.setViewTreeSavedStateRegistryOwner(this)
        frame.setViewTreeViewModelStoreOwner(this)
        frame.addView(compose)
        wm.addView(frame, params)
        root = frame

        // Expanded, the island takes the keyboard (for adding tasks) and the
        // back key; compact, it must never steal focus from the app below.
        watcher = IslandHub.scope.launch {
            snapshotFlow { IslandHub.shape }.collect { shape ->
                val focusable = shape == IslandShape.Expanded
                params.flags = BASE_FLAGS or if (focusable) 0 else WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                root?.let { runCatching { wm.updateViewLayout(it, params) } }
            }
        }
    }

    private val power = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_BATTERY_CHANGED -> {
                    val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                    val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                    if (level >= 0) IslandHub.battery = level * 100 / scale
                    val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                    IslandHub.charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
                }
                Intent.ACTION_POWER_CONNECTED -> if (Settings.showCharging) {
                    IslandHub.charging = true
                    IslandHub.show(Banner(kind = Banner.Kind.Charging, title = "Charging"), seconds = 3)
                }
                Intent.ACTION_TIME_TICK -> {
                    val today = LocalDate.now()
                    if (today != day) {
                        day = today
                        TaskStore.refreshDay()
                    }
                }
                Intent.ACTION_SCREEN_OFF -> IslandHub.close()
            }
        }
    }

    private fun goForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Island running", NotificationManager.IMPORTANCE_MIN).apply {
            setShowBadge(false)
        })
        val openApp = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, IslandService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notify)
            .setContentTitle("Island is on")
            .setContentText("Tap for settings")
            .setContentIntent(openApp)
            .addAction(Notification.Action.Builder(null, "Hide island", stop).build())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, n)
        }
    }

    companion object {
        private const val CHANNEL = "island"
        const val ACTION_STOP = "com.karaman.island.STOP"
        const val ACTION_OPEN = "com.karaman.island.OPEN"
        const val ACTION_DEMO = "com.karaman.island.DEMO"
        private const val BASE_FLAGS =
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED

        var running = false
            private set

        fun start(context: Context) {
            if (!android.provider.Settings.canDrawOverlays(context)) return
            context.startForegroundService(Intent(context, IslandService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, IslandService::class.java))
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences("island", Context.MODE_PRIVATE)
        if (prefs.getBoolean("enabled", true)) IslandService.start(context)
    }
}
