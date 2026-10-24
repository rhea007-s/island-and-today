# Today — Lock Screen task widget for iPhone

A small SwiftUI app plus a WidgetKit extension. The Lock Screen widget shows
what is left to do today and what you have already finished — and you can tick
a task off without unlocking the phone.

## What is here

```
Shared/                  compiled into BOTH targets
  AppGroup.swift         the one shared constant: the App Group id
  DayTask.swift          the model + DaySnapshot (what the widget renders)
  TaskStore.swift        JSON persistence in the App Group container
  HistoryExport.swift    pure renderers: history -> Markdown / CSV / plain text
App/
  TodayApp.swift         app entry, midnight rollover, deep-link handling
  ContentView.swift      the list + composer
  AppRouter.swift        deep-link routes turned into UI intent
  HistoryView.swift      past days, nested subtasks, export via the share sheet
  CalendarSync.swift     two-way sync between scheduled tasks and EventKit
Widget/
  TodayWidgetBundle.swift  widget declaration + supported families
  TodayProvider.swift      TimelineProvider (reload at midnight + on change)
  LockScreenViews.swift    circular / rectangular / inline / small views
  ToggleTaskIntent.swift   AppIntent that completes a task from the Lock Screen
  WidgetPreviews.swift     all four families across empty / mixed / all-done
Entitlements/            App Group entitlement for each target
project.yml              XcodeGen spec (generates the .xcodeproj)
```

## Requirements

- **Xcode 15 or newer** — installed, and `xcode-select -p` already points at
  `/Applications/Xcode.app/Contents/Developer`.
- iOS 17+ deployment target (interactive widget buttons need iOS 17).
- A free Apple ID is enough to run on your own iPhone.

## Why VS Code cannot build this

Only the macOS SDKs ship with Command Line Tools. The iOS SDK, the simulator
runtimes and WidgetKit's previews live inside `Xcode.app`. VS Code with the
Swift extension gives you editing and `sourcekit-lsp`; the actual build has to
go through Xcode's toolchain. Now that Xcode is installed the
`.vscode/tasks.json` here drives the same `./run.sh` from the editor.

The HTML mock in `demo.html` needs none of that: right-click it in VS Code and
pick **Open with Live Server**.

## One command, once Xcode is installed

```sh
./run.sh
```

Checks the toolchain, installs XcodeGen if missing, generates the project,
picks the newest available iOS 17+ iPhone simulator, builds, installs,
launches, and drops a `sim-app.png` screenshot next to this file. It refuses
early with the exact command to run if Xcode is not the active developer
directory.

Fastest way to judge the widget itself is the Xcode canvas rather than the
simulator's Lock Screen: open `Widget/WidgetPreviews.swift` and press
Cmd+Opt+Enter. All four families render with the real vibrant treatment across
empty / mixed / all-done states.

## Getting it into Xcode

### Option A — XcodeGen (recommended)

```sh
brew install xcodegen
cd ~/Desktop/TodayWidget
xcodegen generate
open TodayWidget.xcodeproj
```

### Option B — by hand

1. Xcode → new iOS App named `Today`, SwiftUI, bundle id `com.karaman.today`.
2. File → New → Target → **Widget Extension**, name `TodayWidget`,
   uncheck "Include Live Activity", uncheck "Include Configuration Intent".
3. Delete the template files Xcode generated in both targets.
4. Drag `App/` into the app target, `Widget/` into the widget target, and
   `Shared/` into **both** (check both boxes in the dialog).
5. For each target: Signing & Capabilities → **+ Capability → App Groups** →
   add `group.com.karaman.today`.
6. App target → Info → URL Types → add scheme `today`.

## Running it

1. Select your iPhone (or an iPhone simulator) and run the `Today` scheme.
2. Add a couple of tasks.
3. Lock Screen → long-press → Customise → tap a widget slot → pick **Today**.
   - the **circular** slot gives you the progress ring,
   - the **rectangular** slot (under the clock) shows the task and is tappable,
   - the **inline** slot (above the clock) gives you one line of text.

To see the widget in the simulator's Lock Screen, lock it with `Cmd+L`.

## How the two processes stay in sync

The widget runs in its own process, so it cannot see the app's memory. Both
read and write one JSON file inside the App Group container. Every mutation
goes through `TaskStore.mutate`, which re-reads the file, applies the change,
writes it atomically, and calls `WidgetCenter.shared.reloadAllTimelines()`.
That is why `ToggleTaskIntent` can change data the app also owns without the
two drifting apart.

## Deep links

The widget's tap target depends on the day. With tasks present the widget opens
`today://today`; on an empty day the whole widget becomes an add affordance and
opens `today://add`, which `AppRouter` turns into a focused composer. Route
names live in `AppGroup.Route` so neither target can drift from the other.

## Ideas worth adding later

- `WidgetConfigurationIntent` so each widget slot can pin a specific list.
- A streak count (`completedAt` is already stored for this).
- Live Activity for a task you are actively working on.
- iCloud sync via `NSUbiquitousKeyValueStore` or CloudKit.

## Island — the Mac side (macOS 14+)

A Dynamic-Island-style panel that lives in the MacBook notch (or as a pill
under the menu bar on displays without one). Same task model as the iPhone
app, plus the IslandOS ideas:

| Tab | What it does |
|---|---|
| Today | today's tasks + subtasks, tick, add, start a focus session on a task |
| Focus | Pomodoro (15/25/50 min, auto break), pinned to a task, survives relaunch |
| Music | Music / Spotify now playing + controls (AppleScript; asks Automation once) |
| Clipboard | last 30 text copies, memory only, password-manager copies skipped |
| System | CPU, memory, battery, Mac model + chip, notch detection |

Compact: wings show a running focus timer, else music. Hover → one-line
peek of the next task. Click → full panel. Esc / click outside → closes.

```
./island.sh            # build Release, install to /Applications, open
./island.sh focus      # …and open expanded on a tab
```

Files: `Island/` (Mac only) + `Shared/` (both; `FocusActivity.swift` is
iPhone-only — ActivityKit does not exist on macOS). The Mac keeps its own
list in `~/Library/Application Support/Island/tasks.json`; iPhone and Mac
do **not** sync yet (needs iCloud, i.e. a paid developer account).


## iPhone ↔ Mac sync (Firestore) and the iPhone calendar

- **Sync:** iPhone → cloud button (top left); Mac → Island Settings → *Sync with iPhone*.
  Sign in with the same email on both. Tasks live in `users/{uid}/tasks/{id}`
  (`json`, `updatedAt`, `deleted`, server `syncedAt`); newest `updatedAt` wins,
  deletions are tombstones. Code: `Shared/CloudSync.swift`, `Shared/SyncView.swift`.
  Rules: `firestore.rules` (each user sees only their own data).
- **Calendar on iPhone:** *Up Next* widget (Home Screen small/medium/large, Lock
  Screen rectangular/inline/circular) in `Widget/CalendarWidget.swift`; meeting
  countdown Live Activity (Dynamic Island on 14 Pro+, Lock Screen elsewhere) in
  `Widget/MeetingLiveActivity.swift`; in-app list in `App/ScheduleSection.swift`.
- **Install on iPhone:** plug it in, unlock, tap Trust, then `./iphone.sh`.
- **Claude Code usage** on the Mac island's System tab: `Island/Modules/AIUsage.swift`
  reads `~/.claude/projects/**/*.jsonl` locally.

## Android tablet island

`Android/` holds a native Kotlin + Jetpack Compose version of the island for
Android tablets (Android 10+). It runs as an overlay at the top centre of the
screen, above every app:

- **Resting pill** grows wings for a running focus timer, a meeting starting
  within 10 minutes, or music (album art + equalizer in the art's colour).
- **Banners** drop down for incoming notifications (tap to open) and for the
  charger being plugged in.
- **Expanded** (tap or swipe down): Today (same tasks as the iPhone and Mac via
  Firestore — sign in with the same account), Focus, Music controls, System.
- Swipe up, tap outside, or press back to close.

Build and install: plug the tablet in with USB debugging on, then

```
./android.sh
```

The script builds a release APK (output in `~/Library/Caches/IslandAndroid`,
outside iCloud), installs it, and grants overlay, notification-listener and
calendar access over adb so nothing has to be tapped through Settings.
Without a cable: `./android.sh pair IP:PORT` from Developer options →
Wireless debugging, then `adb connect IP:PORT` and `./android.sh`.
