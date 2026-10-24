package com.karaman.island

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.launch

/** Setup and settings. The island itself lives in [IslandService]. */
class MainActivity : ComponentActivity() {
    // Bumped on resume so permission rows re-check after a trip to Settings.
    private var resumes by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.action == IslandService.ACTION_DEMO) {
            startForegroundService(Intent(this, IslandService::class.java).setAction(IslandService.ACTION_DEMO))
            finish()
            return
        }
        enableEdgeToEdge()
        Settings.load(this)
        TaskStore.load(this)
        CloudSync.load(this)
        lifecycle.addObserver(LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_RESUME) {
                resumes++
                if (enabled() && AndroidSettings.canDrawOverlays(this)) IslandService.start(this)
            }
        })
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Settings.accent)) {
                @Suppress("UNUSED_EXPRESSION") resumes
                Screen()
            }
        }
    }

    private fun enabled() = getSharedPreferences("island", MODE_PRIVATE).getBoolean("enabled", true)
    private fun setEnabled(on: Boolean) {
        getSharedPreferences("island", MODE_PRIVATE).edit().putBoolean("enabled", on).apply()
        if (on) IslandService.start(this) else IslandService.stop(this)
    }

    @Composable
    private fun Screen() {
        val overlay = AndroidSettings.canDrawOverlays(this)
        val listener = IslandListener.isEnabled(this)
        val calendar = checkSelfPermission(Manifest.permission.READ_CALENDAR) == android.content.pm.PackageManager.PERMISSION_GRANTED
        var on by remember { mutableStateOf(enabled()) }

        Box(Modifier.fillMaxSize().background(Color(0xFF0B0B0F)), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 640.dp).fillMaxWidth().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Spacer(Modifier.height(40.dp))
                Text("Island", color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Bold)
                Text("A Dynamic Island for this tablet — music, notifications, focus and today's tasks, synced with your iPhone and Mac.",
                    color = Color.White.copy(alpha = 0.6f), fontSize = 15.sp)

                Section("Setup") {
                    Step("Draw over other apps", "Needed to show the island", overlay) {
                        startActivity(Intent(AndroidSettings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    }
                    Step("Notification access", "Music controls and notification banners", listener) {
                        startActivity(Intent(AndroidSettings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    }
                    Step("Calendar", "Shows meetings about to start", calendar) {
                        requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), 2)
                    }
                    Toggle("Show the island", on && overlay) {
                        on = it
                        setEnabled(it)
                    }
                }

                Section("Look") {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        IslandStyle.entries.forEach { s ->
                            val sel = Settings.style == s
                            Box(
                                Modifier.clip(RoundedCornerShape(12.dp))
                                    .border(if (sel) 2.dp else 1.dp, if (sel) Settings.accent else Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
                                    .clickable { Settings.style = s; Settings.save() }
                                    .padding(horizontal = 18.dp, vertical = 10.dp),
                            ) { Text(s.title, color = Color.White) }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Settings.accents.forEachIndexed { i, c ->
                            Box(
                                Modifier.size(32.dp).clip(CircleShape).background(c)
                                    .border(if (Settings.accentIndex == i) 3.dp else 0.dp, Color.White, CircleShape)
                                    .clickable { Settings.accentIndex = i; Settings.save() },
                            )
                        }
                    }
                    SliderRow("Width", Settings.pillWidth, 90f..260f) { Settings.pillWidth = it }
                    SliderRow("Height", Settings.pillHeight, 24f..48f) { Settings.pillHeight = it }
                    SliderRow("Distance from top", Settings.topOffset, 0f..80f) { Settings.topOffset = it }
                    if (Settings.topOffset < Settings.statusBarDp(this@MainActivity)) {
                        Text("Inside the status bar the island is visible, but Android sends taps there to the status bar.",
                            color = Color(0xFFFF9F0A), fontSize = 13.sp)
                    }
                    OutlinedButton(onClick = { IslandHub.open() }) { Text("Open the island") }
                }

                Section("Behaviour") {
                    Toggle("Notification banners", Settings.showNotifications) { Settings.showNotifications = it; Settings.save() }
                    Toggle("Charging banner", Settings.showCharging) { Settings.showCharging = it; Settings.save() }
                    Toggle("Music in the resting island", Settings.showMusicInCompact) { Settings.showMusicInCompact = it; Settings.save() }
                    Toggle("Vibration", Settings.haptics) { Settings.haptics = it; Settings.save() }
                    SliderRow("Focus minutes", Settings.focusMinutes.toFloat(), 5f..90f, step = true) { Settings.focusMinutes = it.toInt() }
                    SliderRow("Break minutes", Settings.breakMinutes.toFloat(), 1f..30f, step = true) { Settings.breakMinutes = it.toInt() }
                }

                Section("Task sync") { SyncBox() }

                Text("Tap the island to open it, swipe down to expand, swipe up or tap outside to close. Long-press a task to delete it; long-press the island while music plays to open the player.",
                    color = Color.White.copy(alpha = 0.45f), fontSize = 13.sp)
                Spacer(Modifier.height(40.dp))
            }
        }
    }

    @Composable
    private fun SyncBox() {
        val scope = rememberCoroutineScope()
        if (CloudSync.isSignedIn && CloudSync.status !is CloudSync.Status.Syncing || CloudSync.email != null && CloudSync.status == CloudSync.Status.Idle) {
            Text("Signed in as ${CloudSync.email}", color = Color.White)
            val st = CloudSync.status
            if (st is CloudSync.Status.Failed) Text(st.message, color = Color(0xFFFF453A), fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(onClick = { CloudSync.sync() }) { Text("Sync now") }
                OutlinedButton(onClick = { CloudSync.signOut() }) { Text("Sign out") }
            }
            return
        }
        var email by remember { mutableStateOf("") }
        var password by remember { mutableStateOf("") }
        Text("Use the same account as the iPhone app and the Mac island.", color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp)
        OutlinedTextField(email, { email = it }, label = { Text("Email") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth())
        OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
        val st = CloudSync.status
        if (st is CloudSync.Status.Failed) Text(st.message, color = Color(0xFFFF453A), fontSize = 13.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(enabled = st != CloudSync.Status.Syncing, onClick = { scope.launch { CloudSync.signIn(email.trim(), password, false) } }) { Text("Sign in") }
            OutlinedButton(enabled = st != CloudSync.Status.Syncing, onClick = { scope.launch { CloudSync.signIn(email.trim(), password, true) } }) { Text("Create account") }
        }
    }

    @Composable
    private fun Section(title: String, content: @Composable () -> Unit) {
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.06f)).padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(title.uppercase(), color = Color.White.copy(alpha = 0.45f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            content()
        }
    }

    @Composable
    private fun Step(title: String, detail: String, done: Boolean, action: () -> Unit) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, color = Color.White, fontSize = 16.sp)
                Text(detail, color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp)
            }
            if (done) Text("✓ On", color = Color(0xFF34C759), fontWeight = FontWeight.SemiBold)
            else Button(onClick = action, colors = ButtonDefaults.buttonColors(containerColor = Settings.accent)) { Text("Allow") }
        }
    }

    @Composable
    private fun Toggle(title: String, value: Boolean, set: (Boolean) -> Unit) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Switch(value, set, colors = SwitchDefaults.colors(checkedTrackColor = Settings.accent))
        }
    }

    @Composable
    private fun SliderRow(title: String, value: Float, range: ClosedFloatingPointRange<Float>, step: Boolean = false, set: (Float) -> Unit) {
        Column {
            Row {
                Text(title, color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
                Text(value.toInt().toString(), color = Color.White.copy(alpha = 0.5f))
            }
            Slider(
                value, { set(it) }, valueRange = range,
                steps = if (step) (range.endInclusive - range.start).toInt() - 1 else 0,
                onValueChangeFinished = { Settings.save() },
                colors = SliderDefaults.colors(thumbColor = Settings.accent, activeTrackColor = Settings.accent),
            )
        }
    }
}

