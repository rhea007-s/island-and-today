import AppKit
import SwiftUI

/// A borderless panel that floats above the menu bar, on every Space and over
/// full-screen apps. It can become key (so the quick-add field takes typing)
/// without activating the app or stealing focus from what you were doing.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Without this the first click on a panel that is not key only makes it key
/// — the button under the pointer never hears it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel and keeps it exactly as big as the island.
///
/// The first version used one big, mostly transparent panel and switched
/// `ignoresMouseEvents` on and off as the pointer moved. That raced: a click
/// that arrived before the switch fell through to the app underneath, which
/// also counted as "clicked outside" and shut the island. Now the panel *is*
/// the island's size (plus room for its shadow), so it always takes clicks
/// and never covers anything it does not draw on.
@MainActor
final class IslandController {
    private let model: IslandModel
    private let panel = IslandPanel()
    private var monitors: [Any] = []
    private var hovering = false
    private var leaveTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?

    init(model: IslandModel) {
        self.model = model
        // The hosting view sits inside a plain container and is sized by an
        // autoresizing mask, not constraints. Resizing a window whose content
        // view *is* an NSHostingView re-enters its constraint pass and AppKit
        // throws ("needs update constraints" while updating constraints).
        let host = FirstClickHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(host)
        panel.contentView = container
        host.frame = container.bounds
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        followIslandSize()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        // Hover: global monitor while another app is frontmost, local while
        // the pointer is over our own panel. Neither needs a permission.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.track() }
            return event
        }) { monitors.append(local) }

        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(keyCode: event.keyCode, flags: event.modifierFlags, chars: event.charactersIgnoringModifiers) }
            return handled ? nil : event
        }) { monitors.append(keys) }

        // A click that reaches another app is, by definition, outside.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .expanded,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                IslandModel.lastReason = "outside click at \(NSEvent.mouseLocation)"
                self.model.close()
            }
        }) { monitors.append(outside) }
    }

    /// Esc closes; ← → (or ⌘1…⌘5) switch pages while open.
    private func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, chars: String?) -> Bool {
        guard model.state == .expanded else { return false }
        // Typing in the quick-add field must keep its arrow keys.
        if panel.firstResponder is NSTextView { if keyCode == 53 { model.close(); return true }
            return false }
        let all = IslandTab.allCases
        let i = all.firstIndex(of: model.tab) ?? 0
        switch keyCode {
        case 53: model.close()
        case 123: model.select(all[(i - 1 + all.count) % all.count])
        case 124: model.select(all[(i + 1) % all.count])
        default:
            if flags.contains(.command), let n = Int(chars ?? ""), (1...all.count).contains(n) {
                model.select(all[n - 1])
            } else {
                return false
            }
        }
        return true
    }

    // MARK: - Sizing

    /// Re-runs whenever anything that feeds `model.size` changes — state,
    /// wings, banner, or the size sliders in Settings.
    private func followIslandSize() {
        withObservationTracking {
            _ = model.size
        } onChange: { [weak self] in
            // Next turn of the run loop, never inside the current layout pass.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.resize()
                    self?.followIslandSize()
                }
            }
        }
    }

    /// Growing happens at once, before the spring starts, so nothing is ever
    /// clipped. Shrinking waits for the closing spring to settle first.
    private func resize() {
        let target = panelFrame()
        shrinkTask?.cancel()
        if target.width >= panel.frame.width && target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
        } else {
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.panel.setFrame(self.panelFrame(), display: true)
            }
        }
    }

    private func panelFrame() -> CGRect {
        let screen = model.geometry.screenFrame
        let size = model.drawnSize
        // Room for the shadow when it shows; a hairline of slack otherwise.
        let margin: CGFloat = model.state == .compact ? 2 : 34
        let width = size.width + margin * 2
        let height = size.height + margin
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    private func reposition() {
        guard let screen = NotchGeometry.preferredScreen else { return }
        model.geometry = NotchGeometry.measure(screen)
        panel.setFrame(panelFrame(), display: true)
    }

    // MARK: - Hover

    private var islandRect: CGRect {
        let screen = model.geometry.screenFrame
        let size = model.drawnSize
        return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
            .insetBy(dx: -6, dy: -6)
    }

    private func track() {
        let inside = islandRect.contains(NSEvent.mouseLocation)
        guard inside != hovering else { return }
        hovering = inside
        leaveTask?.cancel()

        if inside {
            model.hover(true)
        } else {
            let grace = model.state == .expanded ? 450 : 180
            leaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(grace))
                guard !Task.isCancelled, let self, !self.hovering else { return }
                IslandModel.lastReason = "pointer left at \(NSEvent.mouseLocation)"
                self.model.hover(false)
                if self.panel.isKeyWindow { self.panel.resignKey() }
            }
        }
    }

    // MARK: - Self-test

    /// `--args -IslandSelfTest YES`: opens the island and clicks every tab
    /// icon through the panel's own event path, printing what happened.
    func selfTest() {
        model.open(.today)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            var failures = 0
            for tab in [IslandTab.focus, .music, .clipboard, .system, .today] {
                click(tabCenter(tab))
                try? await Task.sleep(for: .milliseconds(600))
                let ok = model.tab == tab && model.state == .expanded
                if !ok { failures += 1 }
                print("SELFTEST \(ok ? "ok  " : "FAIL") click \(tab.rawValue) → tab=\(model.tab.rawValue) state=\(model.state)")
            }
            print("SELFTEST panel=\(panel.frame.size) island=\(model.drawnSize) failures=\(failures)")
            NSApp.terminate(nil)
        }
    }

    private func click(_ point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
        }
    }

    /// Where a tab icon sits, in panel coordinates (origin bottom-left).
    private func tabCenter(_ tab: IslandTab) -> CGPoint {
        let island = model.drawnSize
        let left = (panel.frame.width - island.width) / 2 + model.cornerTop + 14
        let right = (panel.frame.width + island.width) / 2 - model.cornerTop - 14
        let y = panel.frame.height - model.baseSize.height / 2
        switch tab {
        case .today: return CGPoint(x: left + 15, y: y)
        case .focus: return CGPoint(x: left + 49, y: y)
        case .music: return CGPoint(x: left + 83, y: y)
        case .clipboard: return CGPoint(x: right - 83, y: y)
        case .system: return CGPoint(x: right - 49, y: y)
        }
    }
}
