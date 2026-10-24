import SwiftUI

/// The Mac island: no Dock icon, no main window — the panel that sits in the
/// notch, a small menu-bar icon for the things every app needs (open,
/// settings, quit), and a Settings window.
@main
struct IslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            IslandMenu(model: delegate.model)
        } label: {
            Image(systemName: "capsule.fill")
        }

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

/// What the menu-bar icon offers. Without a Dock icon this is how people find
/// Settings and Quit, like any other menu-bar utility.
private struct IslandMenu: View {
    let model: IslandModel

    var body: some View {
        Button("Open Island") { model.open() }
            .keyboardShortcut("o")
        Menu("Go to") {
            ForEach(IslandTab.allCases) { tab in
                Button(tab.title) { model.open(tab) }
            }
        }
        Divider()
        Toggle("Start at Login", isOn: Binding(
            get: { model.settings.launchAtLogin },
            set: { model.settings.launchAtLogin = $0 }
        ))
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Text("Island \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        Button("Quit Island") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var controller: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TaskStore.shared.rolloverUnfinished()
        // Pull what the iPhone changed every minute; local edits push at once.
        CloudSync.shared.start(polling: 60)
        controller = IslandController(model: model)
        controller?.show()

        // A notch app is only useful if it is there after a restart, so the
        // first launch turns this on. The menu and Settings switch it off.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didSetUpLoginItem") {
            defaults.set(true, forKey: "didSetUpLoginItem")
            model.settings.launchAtLogin = true
        }

        // `open Island.app --args -IslandOpenTab focus` starts expanded on a
        // tab — for screenshots and for checking a layout without hovering.
        if let raw = defaults.string(forKey: "IslandOpenTab"), let tab = IslandTab(rawValue: raw) {
            model.open(tab)
        }
        if defaults.bool(forKey: "IslandSelfTest") { controller?.selfTest() }
    }

    /// Double-clicking Island in Applications or Launchpad while it already
    /// runs opens the island, instead of seeming to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.open()
        return false
    }
}
