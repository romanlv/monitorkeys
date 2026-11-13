import AppKit

/// Software dimming: a click-through black window over one display. It darkens whatever is drawn
/// below it, so it works alongside apps that own the display's colour table (f.lux, calibration)
/// without touching that table. The pointer, the screen saver, the lock screen and apps that
/// capture the whole display stay undimmed.
final class Shade {
    /// Above menus, the menu bar and the Dock, below the screen saver.
    static let windowLevel = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 2)
    /// For our own indicators that must stay readable over the overlay; still below the screen saver.
    static let aboveLevel = NSWindow.Level(windowLevel.rawValue + 1)

    private let display: CGDirectDisplayID
    private var window: NSWindow?
    /// The display's frame, looked up on first use and after screens change; nil while it has no screen.
    private var frame: NSRect?
    private var screensObserver: NSObjectProtocol?
    /// 1 = no dimming.
    private(set) var level: Double = 1

    init(display: CGDirectDisplayID) {
        self.display = display
        // The display may have moved, changed resolution, or just appeared.
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reframe() }
    }

    deinit {
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        window?.close()
    }

    func write(_ level: Double) {
        self.level = min(max(level, 0), 1)
        update()
    }

    private func reframe() {
        frame = nil
        update()
    }

    private func update() {
        guard level < 1 else {
            window?.orderOut(nil)
            return
        }
        if frame == nil { frame = NSScreen.forDisplay(display)?.frame }
        guard let frame else {
            window?.orderOut(nil) // no screen to cover yet; reframe() shows it once there is
            return
        }
        let w = window ?? makeWindow()
        window = w
        if w.frame != frame { w.setFrame(frame, display: false) }
        w.alphaValue = 1 - level
        if !w.isVisible { w.orderFrontRegardless() }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        // A solid layer colour, so there is no full-display bitmap to keep.
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = view
        view.setAccessibilityElement(false) // not a window VoiceOver or window tools should see
        w.setAccessibilityElement(false)
        w.isExcludedFromWindowsMenu = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.canHide = false // Hide Others must not take the dimming away
        w.sharingType = .none // kept out of screenshots and sharing where macOS honours this
        w.level = Self.windowLevel
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return w
    }
}
