package com.karaman.island

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.Event
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

private val White = Color.White
private val Dim = Color.White.copy(alpha = 0.55f)
private val Faint = Color.White.copy(alpha = 0.08f)

/** What the resting island shows in its wings, one thing at a time. */
private sealed interface Live {
    data class Note(val banner: Banner) : Live
    data object Focus : Live
    data class Meeting(val event: CalendarFeed.Event) : Live
    data class Music(val info: NowPlayingInfo) : Live
    data object None : Live
}

private fun currentLive(): Live {
    IslandHub.banner?.let { return Live.Note(it) }
    if (FocusTimer.isActive) return Live.Focus
    CalendarFeed.soon()?.let { return Live.Meeting(it) }
    val m = IslandHub.music
    if (Settings.showMusicInCompact && m != null && m.playing) return Live.Music(m)
    return Live.None
}

// Opening pops with a little bounce; closing settles without overshoot — the
// same feel as the Mac island (response 0.42/0.78 open, 0.34/1.0 close).
private fun <T> openSpring() = spring<T>(dampingRatio = 0.72f, stiffness = 380f)
private fun <T> closeSpring() = spring<T>(dampingRatio = 1f, stiffness = 520f)

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Island() {
    val context = LocalContext.current
    val shape = IslandHub.shape
    val live = currentLive()
    val expanded = shape == IslandShape.Expanded
    val opening = expanded || live !is Live.None

    // Clock tick so "in 4 min" and the meeting wings stay current.
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(15_000)
            now = Instant.now()
            CalendarFeed.refresh(context)
        }
    }

    val targetW: Dp
    val targetH: Dp
    when {
        expanded -> { targetW = 480.dp; targetH = 330.dp }
        live is Live.Note -> { targetW = 400.dp; targetH = 70.dp }
        live !is Live.None -> { targetW = Settings.pillWidth.dp + 120.dp; targetH = Settings.pillHeight.dp }
        else -> { targetW = Settings.pillWidth.dp; targetH = Settings.pillHeight.dp }
    }
    val w by animateDpAsState(targetW, if (opening) openSpring() else closeSpring(), label = "w")
    val h by animateDpAsState(targetH, if (opening) openSpring() else closeSpring(), label = "h")
    val radius by animateDpAsState(
        if (expanded) 36.dp else if (live is Live.Note) 35.dp else Settings.pillHeight.dp / 2,
        if (opening) openSpring() else closeSpring(), label = "r",
    )
    val islandShape = RoundedCornerShape(radius)
    val resting = !expanded && live is Live.None

    // Room around the island for its shadow; none at rest so the touch area
    // is exactly the pill.
    val pad = if (resting) 0.dp else 14.dp
    Box(Modifier.padding(start = pad, end = pad, bottom = pad, top = Settings.topOffset.dp)) {
        Box(
            Modifier
                .size(w, h)
                .islandSurface(islandShape, resting)
                .clip(islandShape)
                .pointerInput(expanded) {
                    var total = 0f
                    detectVerticalDragGestures(
                        onDragStart = { total = 0f },
                        onDragEnd = {
                            if (total > 40 && !expanded) { Haptics.buzz(); IslandHub.open() }
                            if (total < -40) { IslandHub.dismissBanner(); IslandHub.close() }
                        },
                    ) { _, dy -> total += dy }
                }
                .combinedClickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {
                        if (expanded) return@combinedClickable
                        val b = IslandHub.banner
                        if (b?.tap != null) {
                            runCatching { b.tap.send() }
                            IslandHub.dismissBanner()
                        } else {
                            Haptics.buzz()
                            IslandHub.open(defaultTab(live))
                        }
                    },
                    onLongClick = {
                        Haptics.buzz()
                        if (live is Live.Music) IslandListener.openPlayer(context) else IslandHub.open()
                    },
                ),
        ) {
            AnimatedContent(
                targetState = when {
                    expanded -> "expanded"
                    live is Live.Note -> "note"
                    live is Live.None -> "none"
                    else -> "wings"
                },
                transitionSpec = {
                    (fadeIn(tween(220, delayMillis = 90)) + scaleIn(tween(260, delayMillis = 60), initialScale = 0.92f))
                        .togetherWith(fadeOut(tween(90)))
                },
                label = "content",
            ) { mode ->
                when (mode) {
                    "expanded" -> Expanded()
                    "note" -> (live as? Live.Note)?.let { NoteBanner(it.banner) }
                    "wings" -> Wings(live, now)
                    else -> Box(Modifier.fillMaxSize())
                }
            }
        }
    }
}

private fun defaultTab(live: Live) = when (live) {
    is Live.Music -> IslandTab.Music
    Live.Focus -> IslandTab.Focus
    else -> IslandHub.tab
}

private fun Modifier.islandSurface(shape: Shape, resting: Boolean): Modifier = when (Settings.style) {
    IslandStyle.Apple -> this
        .shadow(if (resting) 0.dp else 18.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
        .background(Color.Black, shape)
        .border(1.dp, Brush.verticalGradient(listOf(White.copy(alpha = if (resting) 0f else 0.16f), White.copy(alpha = 0.02f))), shape)
    IslandStyle.Cartoon -> this
        .background(Settings.accent, shape)
        .padding(bottom = if (resting) 2.dp else 5.dp)
        .background(Brush.verticalGradient(listOf(Color(0xFF2B2645), Color(0xFF171427))), shape)
        .border(if (resting) 2.dp else 3.dp, White, shape)
}

// MARK: - Compact wings

@Composable
private fun Wings(live: Live, now: Instant) {
    Row(
        Modifier.fillMaxSize().padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when (live) {
            is Live.Music -> {
                // The cover opens the song in its player; the rest of the pill opens the island.
                val context = LocalContext.current
                Box(Modifier.clip(RoundedCornerShape(6.dp)).clickable { Haptics.buzz(); IslandListener.openPlayer(context) }) {
                    Artwork(live.info.art, 22.dp, 6.dp)
                }
                Spacer(Modifier.weight(1f))
                Equalizer(live.info.art?.let(::averageColor) ?: Settings.accent, live.info.playing)
            }
            Live.Focus -> {
                Ring(FocusTimer.progress, if (FocusTimer.phase == FocusTimer.Phase.Work) Settings.accent else Color(0xFF34C759), 20.dp, 3.dp)
                Spacer(Modifier.weight(1f))
                Text(FocusTimer.format(FocusTimer.remaining), color = White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
            }
            is Live.Meeting -> {
                Icon(Icons.Rounded.Event, null, tint = Color(0xFFFF9F0A), modifier = Modifier.size(18.dp))
                Spacer(Modifier.weight(1f))
                Text(untilText(live.event, now), color = Color(0xFFFF9F0A), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
            else -> {}
        }
    }
}

@Composable
private fun NoteBanner(b: Banner) {
    Row(
        Modifier.fillMaxSize().padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when (b.kind) {
            Banner.Kind.Charging -> Icon(Icons.Rounded.Bolt, null, tint = Color(0xFF34C759), modifier = Modifier.size(34.dp))
            Banner.Kind.Focus -> Icon(Icons.Rounded.Timer, null, tint = Settings.accent, modifier = Modifier.size(32.dp))
            else -> if (b.icon != null) Artwork(b.icon, 40.dp, 12.dp) else
                Icon(Icons.Rounded.Event, null, tint = Settings.accent, modifier = Modifier.size(32.dp))
        }
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(b.title, color = White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (b.text.isNotEmpty()) Text(b.text, color = Dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (b.kind == Banner.Kind.Charging) {
            Text("${IslandHub.battery}%", color = Color(0xFF34C759), fontSize = 17.sp, fontWeight = FontWeight.Bold)
        }
    }
}

// MARK: - Expanded

@Composable
private fun Expanded() {
    Column(Modifier.fillMaxSize().padding(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IslandTab.entries.forEach { t ->
                val selected = IslandHub.tab == t
                val bg by animateFloatAsState(if (selected) 0.16f else 0f, label = "tab")
                Row(
                    Modifier
                        .clip(CircleShape)
                        .background(White.copy(alpha = bg))
                        .clickable { Haptics.buzz(); IslandHub.tab = t }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(t.icon, null, tint = if (selected) White else Dim, modifier = Modifier.size(17.dp))
                    if (selected) {
                        Spacer(Modifier.width(6.dp))
                        Text(t.title, color = White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Text("${IslandHub.battery}%", color = if (IslandHub.charging) Color(0xFF34C759) else Dim, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(14.dp))
        var last by remember { mutableStateOf(IslandHub.tab) }
        AnimatedContent(
            targetState = IslandHub.tab,
            transitionSpec = {
                val dir = if (targetState.ordinal > initialState.ordinal) 1 else -1
                (slideInHorizontally(spring(stiffness = Spring.StiffnessMediumLow)) { it / 5 * dir } + fadeIn())
                    .togetherWith(slideOutHorizontally(spring(stiffness = Spring.StiffnessMediumLow)) { -it / 5 * dir } + fadeOut(tween(120)))
            },
            label = "tab",
        ) { t ->
            last = t
            when (t) {
                IslandTab.Today -> TodayTab()
                IslandTab.Focus -> FocusTab()
                IslandTab.Music -> MusicTab()
                IslandTab.Claude -> ClaudeTab()
                IslandTab.System -> SystemTab()
            }
        }
    }
}

private val IslandTab.icon: ImageVector
    get() = when (this) {
        IslandTab.Today -> Icons.Rounded.Checklist
        IslandTab.Focus -> Icons.Rounded.Timer
        IslandTab.Music -> Icons.Rounded.MusicNote
        IslandTab.Claude -> Icons.Rounded.AutoAwesome
        IslandTab.System -> Icons.Rounded.Memory
    }

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TodayTab() {
    val tasks = IslandHub.tasks
    val leaves = tasks.filter { t -> tasks.none { it.parentID == t.id } }
    val done = leaves.count { it.isDone }
    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(LocalDate.now().format(DateTimeFormatter.ofPattern("EEEE, d MMMM", Locale.getDefault())),
                color = White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            if (leaves.isNotEmpty()) Text("$done of ${leaves.size}", color = Dim, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
        IslandHub.nextEvent?.let { e ->
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Event, null, tint = Color(0xFFFF9F0A), modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text("${e.title} · ${untilText(e, Instant.now())}", color = Dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (leaves.isNotEmpty()) {
            val p by animateFloatAsState(done.toFloat() / leaves.size, spring(dampingRatio = 0.85f), label = "p")
            Box(Modifier.padding(vertical = 8.dp).fillMaxWidth().height(4.dp).clip(CircleShape).background(Faint)) {
                Box(Modifier.fillMaxWidth(p).fillMaxHeight().clip(CircleShape).background(Settings.accent))
            }
        }
        LazyColumn(Modifier.weight(1f)) {
            if (tasks.isEmpty()) item {
                Text("Nothing yet — add the first thing below.", color = Dim, fontSize = 12.sp,
                    modifier = Modifier.padding(vertical = 28.dp).fillMaxWidth())
            }
            items(tasks, key = { it.id }) { t ->
                Row(
                    Modifier
                        .animateItem()
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .combinedClickable(
                            onClick = { Haptics.buzz(); TaskStore.toggle(t.id) },
                            onLongClick = { Haptics.buzz(true); TaskStore.delete(t.id) },
                        )
                        .padding(start = if (t.parentID != null) 26.dp else 4.dp, top = 7.dp, bottom = 7.dp, end = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        if (t.isDone) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, null,
                        tint = if (t.isDone) Settings.accent else Dim, modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(t.title, color = if (t.isDone) Dim else White, fontSize = 14.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                        textDecoration = if (t.isDone) TextDecoration.LineThrough else null)
                    if (!t.isDone) Icon(Icons.Rounded.PlayArrow, "Focus on this", tint = Dim,
                        modifier = Modifier.size(28.dp).clip(CircleShape).clickable {
                            Haptics.buzz(); FocusTimer.start(t.title); IslandHub.tab = IslandTab.Focus
                        }.padding(4.dp))
                }
            }
        }
        var draft by remember { mutableStateOf("") }
        Row(
            Modifier.padding(top = 8.dp).fillMaxWidth().height(38.dp).clip(RoundedCornerShape(12.dp)).background(Faint).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.Add, null, tint = Settings.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Box(Modifier.weight(1f)) {
                if (draft.isEmpty()) Text("Add a task for today", color = Dim, fontSize = 14.sp)
                BasicTextField(
                    draft, { draft = it }, singleLine = true,
                    textStyle = TextStyle(color = White, fontSize = 14.sp),
                    cursorBrush = SolidColor(Settings.accent),
                    keyboardOptions = KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { TaskStore.add(draft); draft = "" }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun FocusTab() {
    val active = FocusTimer.isActive
    val color = if (FocusTimer.phase == FocusTimer.Phase.Work) Settings.accent else Color(0xFF34C759)
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        Box(contentAlignment = Alignment.Center) {
            val p by animateFloatAsState(if (active) FocusTimer.progress else 0f, tween(300), label = "ring")
            Ring(p, color, 170.dp, 10.dp)
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(FocusTimer.format(if (active) FocusTimer.remaining else Settings.focusMinutes * 60L),
                    color = White, fontSize = 38.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                Text(if (!active) "Ready" else if (FocusTimer.phase == FocusTimer.Phase.Work) "Focus" else "Break",
                    color = Dim, fontSize = 13.sp)
            }
        }
        Spacer(Modifier.width(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(FocusTimer.taskTitle ?: "No task picked", color = White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 2)
            Text("${FocusTimer.completedToday} sessions today", color = Dim, fontSize = 12.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!active) {
                    RoundButton(Icons.Rounded.PlayArrow, color, big = true) { FocusTimer.start() }
                } else {
                    RoundButton(if (FocusTimer.paused) Icons.Rounded.PlayArrow else Icons.Rounded.Pause, color, big = true) { FocusTimer.togglePause() }
                    RoundButton(Icons.Rounded.SkipNext, Faint) { FocusTimer.skip() }
                    RoundButton(Icons.Rounded.Stop, Faint) { FocusTimer.stop() }
                }
            }
        }
    }
}

@Composable
private fun MusicTab() {
    val m = IslandHub.music
    val context = LocalContext.current
    if (m == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                if (IslandHub.listenerConnected) "Nothing playing" else "Allow notification access in the Island app to see music",
                color = Dim, fontSize = 13.sp,
            )
        }
        return
    }
    val position by produceState(m.positionMs, m) {
        while (true) {
            value = if (m.playing) m.positionMs + (android.os.SystemClock.elapsedRealtime() - m.positionAt) else m.positionMs
            delay(500)
        }
    }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.clickable { IslandListener.openPlayer(context) }) { Artwork(m.art, 92.dp, 18.dp) }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(m.title, color = White, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(m.artist, color = Dim, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Equalizer(m.art?.let(::averageColor) ?: Settings.accent, m.playing)
        }
        Spacer(Modifier.height(18.dp))
        if (m.durationMs > 0) {
            val p = (position.toFloat() / m.durationMs).coerceIn(0f, 1f)
            Box(Modifier.fillMaxWidth().height(5.dp).clip(CircleShape).background(Faint)) {
                Box(Modifier.fillMaxWidth(p).fillMaxHeight().clip(CircleShape).background(White))
            }
            Row(Modifier.padding(top = 4.dp)) {
                Text(mmss(position), color = Dim, fontSize = 11.sp)
                Spacer(Modifier.weight(1f))
                Text("-" + mmss(m.durationMs - position), color = Dim, fontSize = 11.sp)
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            RoundButton(Icons.Rounded.SkipPrevious, Color.Transparent) { IslandListener.transport()?.skipToPrevious() }
            Spacer(Modifier.width(18.dp))
            RoundButton(if (m.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, Faint, big = true) {
                IslandListener.transport()?.let { if (m.playing) it.pause() else it.play() }
            }
            Spacer(Modifier.width(18.dp))
            RoundButton(Icons.Rounded.SkipNext, Color.Transparent) { IslandListener.transport()?.skipToNext() }
        }
    }
}

/**
 * Claude Code usage from the Mac (the tablet has no logs of its own): time
 * left in the 5-hour session, and tokens for the session and the day.
 */
@Composable
private fun ClaudeTab() {
    val c = IslandHub.claude
    val now by produceState(Instant.now()) {
        while (true) { delay(1000); value = Instant.now() }
    }
    if (c == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                if (CloudSync.isSignedIn) "Waiting for the Mac island to share Claude usage…"
                else "Sign in from the Island app — usage comes from the Mac",
                color = Dim, fontSize = 13.sp,
            )
        }
        return
    }
    val start = c.sessionStart
    val end = c.sessionEnd
    val live = start != null && end != null && now < end
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        Box(contentAlignment = Alignment.Center) {
            val left = if (live) Duration.between(now, end).seconds.toFloat() / (5 * 3600) else 0f
            val p by animateFloatAsState(left.coerceIn(0f, 1f), tween(600), label = "session")
            Ring(p, Settings.accent, 170.dp, 10.dp)
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                if (live) {
                    val secs = Duration.between(now, end).seconds
                    Text("%d:%02d:%02d".format(secs / 3600, secs % 3600 / 60, secs % 60),
                        color = White, fontSize = 28.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    Text("until reset", color = Dim, fontSize = 12.sp)
                } else {
                    Text("Fresh", color = White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                    Text("no session running", color = Dim, fontSize = 12.sp)
                }
            }
        }
        Spacer(Modifier.width(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (live) {
                val fmt = DateTimeFormatter.ofPattern("HH:mm").withZone(java.time.ZoneId.systemDefault())
                Text("Resets at ${fmt.format(end)}", color = White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Text("Session started ${fmt.format(start)}", color = Dim, fontSize = 12.sp)
                Stat("This session", "${compact(c.sessionTokens)} tokens · ${c.sessionReplies} replies")
            } else {
                Text("Your next message starts a 5-hour session", color = White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            Stat("Today", "${compact(c.dayTokens)} tokens · ${compact(c.dayOutput)} out · ${c.dayReplies} replies")
            if (c.model.isNotEmpty()) Stat("Mostly", c.model)
            c.updatedAt?.let {
                val ago = Duration.between(it, now).toMinutes()
                Text(if (ago < 1) "Updated just now" else "Updated $ago min ago", color = Dim.copy(alpha = 0.35f), fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Column {
        Text(label.uppercase(), color = Dim, fontSize = 10.sp, fontWeight = FontWeight.Bold)
        Text(value, color = White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun compact(n: Long): String = when {
    n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
    n >= 10_000 -> "%.0fK".format(n / 1_000.0)
    n >= 1_000 -> "%.1fK".format(n / 1_000.0)
    else -> n.toString()
}

@Composable
private fun SystemTab() {
    val context = LocalContext.current
    val s by produceState(SystemStats.read(context)) {
        while (true) { delay(2000); value = SystemStats.read(context) }
    }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(SystemStats.device, color = White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Meter("Battery", IslandHub.battery / 100f, "${IslandHub.battery}%" + if (IslandHub.charging) " · charging" else "",
            if (IslandHub.charging) Color(0xFF34C759) else Settings.accent)
        Meter("Memory", s.ramUsed.toFloat() / s.ramTotal, "${SystemStats.gb(s.ramUsed)} of ${SystemStats.gb(s.ramTotal)}", Color(0xFF64D2FF))
        Meter("Storage", s.diskUsed.toFloat() / s.diskTotal, "${SystemStats.gb(s.diskUsed)} of ${SystemStats.gb(s.diskTotal)}", Color(0xFFFF9F0A))
        val sync = when (val st = CloudSync.status) {
            CloudSync.Status.SignedOut -> "Task sync off — sign in from the Island app"
            CloudSync.Status.Syncing -> "Syncing…"
            CloudSync.Status.Idle -> "Synced with iPhone and Mac · ${CloudSync.email}"
            is CloudSync.Status.Failed -> "Sync failed: ${st.message}"
        }
        Text(sync, color = Dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: - Pieces

@Composable
private fun Meter(label: String, value: Float, detail: String, color: Color) {
    Column {
        Row {
            Text(label, color = White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text(detail, color = Dim, fontSize = 12.sp)
        }
        val v by animateFloatAsState(value.coerceIn(0f, 1f), spring(dampingRatio = 0.85f), label = "meter")
        Box(Modifier.padding(top = 5.dp).fillMaxWidth().height(6.dp).clip(CircleShape).background(Faint)) {
            Box(Modifier.fillMaxWidth(v).fillMaxHeight().clip(CircleShape).background(color))
        }
    }
}

@Composable
private fun RoundButton(icon: ImageVector, bg: Color, big: Boolean = false, onClick: () -> Unit) {
    val size = if (big) 52.dp else 42.dp
    Box(
        Modifier.size(size).clip(CircleShape).background(bg).clickable { Haptics.buzz(); onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = White, modifier = Modifier.size(if (big) 28.dp else 24.dp))
    }
}

@Composable
private fun Artwork(bmp: Bitmap?, size: Dp, corner: Dp) {
    if (bmp != null) {
        Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Crop,
            modifier = Modifier.size(size).clip(RoundedCornerShape(corner)))
    } else {
        Box(Modifier.size(size).clip(RoundedCornerShape(corner)).background(Faint), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.MusicNote, null, tint = Dim, modifier = Modifier.size(size * 0.5f))
        }
    }
}

@Composable
private fun Ring(progress: Float, color: Color, size: Dp, stroke: Dp) {
    Canvas(Modifier.size(size)) {
        val s = stroke.toPx()
        val arc = androidx.compose.ui.geometry.Size(this.size.width - s, this.size.height - s)
        val tl = Offset(s / 2, s / 2)
        drawArc(color.copy(alpha = 0.22f), 0f, 360f, false, tl, arc, style = Stroke(s))
        drawArc(color, -90f, 360f * progress, false, tl, arc, style = Stroke(s, cap = StrokeCap.Round))
    }
}

/** Four bars bouncing out of phase, the colour of the album art. Still when paused. */
@Composable
private fun Equalizer(color: Color, playing: Boolean) {
    val t = rememberInfiniteTransition(label = "eq")
    val bars = listOf(420, 560, 360, 500).mapIndexed { i, ms ->
        t.animateFloat(0.25f, 1f, infiniteRepeatable(tween(ms, delayMillis = i * 40, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b$i")
    }
    Row(Modifier.height(16.dp), horizontalArrangement = Arrangement.spacedBy(2.5.dp), verticalAlignment = Alignment.CenterVertically) {
        bars.forEach { b ->
            Box(Modifier.width(3.dp).fillMaxHeight(if (playing) b.value else 0.25f).clip(CircleShape).background(color))
        }
    }
}

/** Mean colour of the artwork, lifted so it reads on black. */
private val colorCache = mutableMapOf<Int, Color>()
private fun averageColor(b: Bitmap): Color = colorCache.getOrPut(System.identityHashCode(b)) {
    val px = Bitmap.createScaledBitmap(b, 1, 1, true).getPixel(0, 0)
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(px, hsv)
    hsv[1] = (hsv[1] * 1.2f).coerceAtMost(1f)
    hsv[2] = hsv[2].coerceAtLeast(0.75f)
    Color(android.graphics.Color.HSVToColor(hsv))
}

private fun untilText(e: CalendarFeed.Event, now: Instant): String {
    val mins = Duration.between(now, e.start).toMinutes()
    return when {
        now >= e.start -> "now"
        mins < 1 -> "in <1 min"
        mins < 60 -> "in $mins min"
        else -> "at " + DateTimeFormatter.ofPattern("HH:mm").withZone(java.time.ZoneId.systemDefault()).format(e.start)
    }
}

private fun mmss(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
}
