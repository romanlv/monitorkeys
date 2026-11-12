import AppKit
import ApplicationServices
import LumenCore

/// Takes over the keyboard brightness keys while the chosen display (see `KeyTargetMode`) is one
/// Lumen controls. Otherwise (e.g. the built-in panel) the key passes through untouched, so macOS
/// keeps handling it natively.
///
/// Needs Accessibility permission: an active event tap that can swallow events requires it.
/// Only brightness key events are inspected; every other event is returned unchanged.
final class BrightnessKeyTap {
    /// Returns the coordinator that should receive keys for a display, or nil to let macOS handle them.
    var target: (CGDirectDisplayID) -> BlendCoordinator? = { _ in nil }
    /// Which display the keys act on.
    var mode: KeyTargetMode = .pointer
    /// Called after a key changed a display's lumen.
    var onChange: (BlendCoordinator) -> Void = { _ in }

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Presses we consumed, by key and by event shape, so only their matching releases are consumed.
    private var swallowed = Set<Swallowed>()
    private struct Swallowed: Hashable {
        let key: BrightnessKey
        let virtualKey: Bool
    }

    var isRunning: Bool { port != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let systemDefined: CGEventMask = 1 << 14
        let keyDown: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let keyUp: CGEventMask = 1 << CGEventType.keyUp.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: systemDefined | keyDown | keyUp,
                                           callback: brightnessTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("brightness key tap could not be created (Accessibility permission missing?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
        swallowed.removeAll()
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow or interrupted tap off; turn it back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            swallowed.removeAll()
            return pass
        case .keyDown, .keyUp:
            guard let key = BrightnessKeyDecoder.decodeKeyDown(
                virtualKey: event.getIntegerValueField(.keyboardEventKeycode)) else { return pass }
            return press(key, isDown: type == .keyDown, virtualKey: true, flags: event.flags) ? nil : pass
        default:
            guard type.rawValue == 14, // system-defined
                  let ns = NSEvent(cgEvent: event),
                  let p = BrightnessKeyDecoder.decodeSystemDefined(subtype: ns.subtype.rawValue, data1: ns.data1)
            else { return pass }
            return press(p.key, isDown: p.isDown, virtualKey: false, flags: event.flags) ? nil : pass
        }
    }

    /// Returns true when the event was consumed.
    private func press(_ key: BrightnessKey, isDown: Bool, virtualKey: Bool, flags: CGEventFlags) -> Bool {
        let id = Swallowed(key: key, virtualKey: virtualKey)
        guard isDown else {
            // Swallow a release only if we swallowed its press, so macOS never sees half a keystroke.
            return swallowed.remove(id) != nil
        }
        guard let display = mode.display(), let coordinator = target(display) else {
            swallowed.remove(id)
            return false
        }
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        coordinator.set(lumen: LumenStep.next(from: coordinator.lumen, key: key, fine: fine))
        swallowed.insert(id)
        onChange(coordinator)
        return true
    }

}

enum KeyTargetMode: String, CaseIterable {
    // Pointer first: it is the default and the first choice in the menu.
    case pointer, activeWindow

    var title: String {
        switch self {
        case .activeWindow: "Display with the active window"
        case .pointer: "Display under the pointer"
        }
    }

    func display() -> CGDirectDisplayID? {
        switch self {
        case .activeWindow: Self.displayOfActiveWindow() ?? Self.displayUnderPointer()
        case .pointer: Self.displayUnderPointer()
        }
    }

    static func displayUnderPointer() -> CGDirectDisplayID? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }

    /// The display showing most of the frontmost app's front window. Uses only window owner and
    /// bounds from the window list (no titles, no screen contents), so no extra permission is needed.
    static func displayOfActiveWindow() -> CGDirectDisplayID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // The list is front to back; the first normal-layer window of the app is its front window.
        guard let info = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }

        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(bounds, UInt32(ids.count), &ids, &count) == .success, count > 0 else { return nil }
        return ids.prefix(Int(count)).max { a, b in
            area(bounds.intersection(CGDisplayBounds(a))) < area(bounds.intersection(CGDisplayBounds(b)))
        }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

private func brightnessTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

/// A small level indicator shown on the display whose brightness just changed, since macOS only
/// draws its own indicator for displays it controls itself.
final class LevelHUD {
    private var panel: NSPanel?
    private var bar: NSLevelIndicator?
    private var hideWork: DispatchWorkItem?

    func show(level: Double, on display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return }
        let panel = self.panel ?? makePanel()
        bar?.doubleValue = level * 16
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 140))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12

        let icon = NSImageView(frame: NSRect(x: 12, y: 12, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        icon.contentTintColor = .labelColor

        let bar = NSLevelIndicator(frame: NSRect(x: 42, y: 14, width: 164, height: 16))
        bar.levelIndicatorStyle = .discreteCapacity
        bar.minValue = 0
        bar.maxValue = 16
        bar.fillColor = .labelColor

        background.addSubview(icon)
        background.addSubview(bar)
        panel.contentView = background
        self.panel = panel
        self.bar = bar
        return panel
    }
}
