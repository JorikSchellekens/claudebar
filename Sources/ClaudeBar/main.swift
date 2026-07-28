import AppKit
import SwiftUI

/// Borderless always-on-top strip. `.nonactivatingPanel` keeps clicks from
/// stealing focus from whatever you are actually working in.
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let store = UsageStore()
    private var panel: BarPanel!

    private let originKey = "barOrigin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: BarView(store: store))
        hosting.menu = buildMenu()

        panel = BarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Present on every space, and over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        resizeToFit()
        placeWindow()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Usage can move while the Mac sleeps; resync the moment it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke),
            name: NSWorkspace.didWakeNotification, object: nil)

        store.start()

        // Content width changes with the number of meters returned.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resizeToFit() }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show percent used", action: #selector(toggleMode), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Reset position", action: #selector(resetPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClaudeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleMode() {
        store.mode = store.mode.toggled
        resizeToFit()
    }

    /// Keep the toggle's title describing what it will switch *to*.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(at: 0)?.title = store.mode == .left ? "Show percent used" : "Show percent left"
    }

    @objc private func refresh() { store.refresh() }

    @objc private func woke() { store.refresh() }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: originKey)
        placeWindow()
    }

    @objc private func screensChanged() {
        placeWindow()
        panel.orderFrontRegardless()
    }

    private func resizeToFit() {
        guard let hosting = panel.contentView else { return }
        let size = hosting.fittingSize
        guard size.width > 1, abs(size.width - panel.frame.width) > 0.5
                || abs(size.height - panel.frame.height) > 0.5 else { return }
        let origin = panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        clampToScreen()
    }

    /// Default spot: bottom centre of the visible frame, which sits above the Dock.
    private func placeWindow() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size

        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let point = NSPointFromString(saved)
            if v.insetBy(dx: -20, dy: -20).contains(point) {
                panel.setFrameOrigin(point)
                clampToScreen()
                return
            }
        }

        panel.setFrameOrigin(NSPoint(
            x: v.midX - size.width / 2,
            y: v.minY + 6
        ))
    }

    private func clampToScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = panel.frame
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: originKey)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
