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
    private let notifier = Notifier()
    private var panel: BarPanel!


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

        notifier.prepare()
        store.onResetPosition = { [weak self] in
            self?.resetPositionAnimated()
        }
        store.onUsage = { [weak self] usage in
            self?.notifier.evaluate(usage)
        }
        store.start()

        // Content width changes with the number of meters returned, and the
        // bar follows the display the mouse is on.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.resizeToFit()
                self?.followMouseScreen()
            }
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
        UserDefaults.standard.removeObject(forKey: xFractionKey)
        UserDefaults.standard.removeObject(forKey: yOffsetKey)
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

    /// Position is stored relative to the screen - an x fraction of the visible
    /// width and a height above its bottom edge - so it survives a move to a
    /// display of a different size.
    private let xFractionKey = "posXFraction"
    private let yOffsetKey = "posYOffset"

    private let bottomMargin: CGFloat = 6

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? panel.screen ?? NSScreen.main
    }

    /// Default spot: bottom centre of the visible frame, which sits above the Dock.
    private func placeWindow(on screen: NSScreen? = nil) {
        guard let screen = screen ?? currentScreen() else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size

        let defaults = UserDefaults.standard
        if defaults.object(forKey: xFractionKey) != nil {
            let fraction = defaults.double(forKey: xFractionKey)
            let yOffset = defaults.double(forKey: yOffsetKey)
            panel.setFrameOrigin(NSPoint(
                x: v.minX + fraction * (v.width - size.width),
                y: v.minY + yOffset
            ))
        } else {
            panel.setFrameOrigin(NSPoint(
                x: v.midX - size.width / 2,
                y: v.minY + bottomMargin
            ))
        }
        clampToScreen()
    }

    /// Hop to whichever display the mouse is on, keeping the same relative spot.
    private func followMouseScreen() {
        guard let target = currentScreen(), target != panel.screen else { return }
        placeWindow(on: target)
    }

    /// Double-clicking the bar sends it home. A magnetic snap was too easy to
    /// miss and gave no hint it existed.
    @objc private func resetPositionAnimated() {
        UserDefaults.standard.removeObject(forKey: xFractionKey)
        UserDefaults.standard.removeObject(forKey: yOffsetKey)
        guard let screen = currentScreen() else { return }
        let v = screen.visibleFrame
        let target = NSPoint(x: v.midX - panel.frame.width / 2, y: v.minY + bottomMargin)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrameOrigin(target)
        }
    }

    private func clampToScreen() {
        guard let screen = panel.screen ?? currentScreen() else { return }
        let v = screen.visibleFrame
        var f = panel.frame
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
    }

    private func savePosition(origin: NSPoint, screen: NSScreen) {
        let v = screen.visibleFrame
        let travel = v.width - panel.frame.width
        let fraction = travel > 0 ? (origin.x - v.minX) / travel : 0.5
        UserDefaults.standard.set(min(max(fraction, 0), 1), forKey: xFractionKey)
        UserDefaults.standard.set(origin.y - v.minY, forKey: yOffsetKey)
    }

    func windowDidMove(_ notification: Notification) {
        guard let screen = panel.screen else { return }
        savePosition(origin: panel.frame.origin, screen: screen)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
