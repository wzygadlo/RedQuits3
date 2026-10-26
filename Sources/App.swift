import AppKit
import ApplicationServices
import Darwin

struct Config: Codable {
    var enabled = true
    var excludedApps: [String] = ["com.apple.finder"]
}

enum Store {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RedQuits3", isDirectory: true)
    static let url = dir.appendingPathComponent("config.json")
    static var config: Config = {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            NSLog("RQ3: invalid settings; auto-quit disabled: %@", error.localizedDescription)
            return Config(enabled: false)
        }
    }()

    static func save() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
    }
}

func allowedApp(bundleID: String, path: String, excluded: [String]) -> Bool {
    !path.hasPrefix("/System/Library/") && !excluded.contains(bundleID)
        && bundleID != "com.wzygadlo.RedQuits3"
}

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func isCloseButton(_ element: AXUIElement) -> Bool {
    axValue(element, kAXRoleAttribute) as? String == kAXButtonRole
        && axValue(element, kAXSubroleAttribute) as? String == kAXCloseButtonSubrole
}

func buttonFrame(_ button: AXUIElement) -> CGRect? {
    guard let position = axValue(button, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = axValue(button, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0 else { return nil }
    return CGRect(origin: point, size: dimensions)
}

struct PendingClick {
    let frame: CGRect
    let timestamp: TimeInterval

    func releasedInside(at point: CGPoint, timestamp: TimeInterval) -> Bool {
        timestamp >= self.timestamp && frame.contains(point)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: Any?
    private var permissionTimer: Timer?
    private var trusted = false
    private var target: (app: NSRunningApplication, click: PendingClick)?
    private var lockFD: Int32 = -1
    private let debug = ProcessInfo.processInfo.environment["RQ3_DEBUG"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A kernel lock releases on exit, without stale PID files or duplicate watchers.
        lockFD = Darwin.open(NSHomeDirectory() + "/.redquits3.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else {
            NSLog("RQ3: cannot acquire instance lock; exiting")
            NSApp.terminate(nil)
            return
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            NSLog("RQ3: another instance is running; exiting")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "StatusIcon")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("RedQuits3")
        updatePermission()
        permissionTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updatePermission() }
        RunLoop.main.add(permissionTimer!, forMode: .common)
        rebuildMenu()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        NSLog("RQ3: started; Accessibility trusted=%d", trusted ? 1 : 0)
    }

    private func updatePermission() {
        let now = AXIsProcessTrusted()
        guard now != trusted || (now && monitor == nil) else { return }
        trusted = now
        target = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if now {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handleMouse(event)
            }
        }
        NSLog("RQ3: Accessibility trusted=%d; monitor installed=%d", now ? 1 : 0, monitor == nil ? 0 : 1)
        rebuildMenu()
    }

    private func eligible(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.activationPolicy == .regular,
              app.processIdentifier > 1, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let id = app.bundleIdentifier, let path = app.bundleURL?.path else { return false }
        return allowedApp(bundleID: id, path: path, excluded: Store.config.excludedApps)
    }

    private func handleMouse(_ event: NSEvent) {
        guard Store.config.enabled, AXIsProcessTrusted(), let point = event.cgEvent?.location else {
            target = nil
            return
        }
        if event.type == .leftMouseDown {
            target = nil
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success,
                  let app = NSRunningApplication(processIdentifier: pid), eligible(app) else { return }

            // Capture BEFORE mouse-up: afterwards the closed window may no longer exist.
            let button: AXUIElement?
            if isCloseButton(hit) {
                button = hit
            } else {
                let window = axValue(hit, kAXRoleAttribute) as? String == kAXWindowRole
                    ? hit : axElement(hit, kAXWindowAttribute)
                button = window.flatMap { axElement($0, kAXCloseButtonAttribute) }
            }
            guard let button, axValue(button, kAXEnabledAttribute) as? Bool == true,
                  let frame = buttonFrame(button), frame.contains(point) else {
                if debug {
                    NSLog("RQ3: mouse-down on %@; not inside its AX close button", app.localizedName ?? "?")
                }
                return
            }
            target = (app, PendingClick(frame: frame, timestamp: event.timestamp))
            if debug { NSLog("RQ3: captured %@ close button on mouse-down", app.localizedName ?? "?") }
        } else if event.type == .leftMouseUp {
            let captured = target
            target = nil
            guard let captured, captured.click.releasedInside(at: point, timestamp: event.timestamp),
                  eligible(captured.app) else { return }
            let accepted = captured.app.terminate()
            NSLog("RQ3: normal quit requested for %@; accepted=%d", captured.app.localizedName ?? "?", accepted ? 1 : 0)
        }
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        if !trusted || monitor == nil {
            let permission = NSMenuItem(title: "Enable Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            permission.target = self
            menu.addItem(permission)
            menu.addItem(.separator())
        }
        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = Store.config.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit RedQuits3", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        let ready = trusted && monitor != nil
        statusItem.button?.appearsDisabled = !ready || !Store.config.enabled
        statusItem.button?.toolTip = !ready ? "RedQuits3 — Accessibility permission needed"
            : (Store.config.enabled ? "RedQuits3 — enabled" : "RedQuits3 — disabled")
    }

    @objc private func toggleEnabled() {
        target = nil
        Store.config.enabled.toggle()
        do {
            try Store.save()
        } catch {
            Store.config.enabled = false
            let alert = NSAlert()
            alert.messageText = "Could not save RedQuits3 settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        permissionTimer?.invalidate()
        if lockFD >= 0 { Darwin.close(lockFD) }
    }
}

func selfTest() throws {
    let sample = Config(enabled: false, excludedApps: ["test.bundle"])
    let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(sample))
    precondition(!decoded.enabled && decoded.excludedApps == ["test.bundle"])
    precondition(!allowedApp(bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app", excluded: []))
    precondition(!allowedApp(bundleID: "test.bundle", path: "/Applications/Test.app", excluded: ["test.bundle"]))
    precondition(!allowedApp(bundleID: "com.wzygadlo.RedQuits3", path: "/Applications/RedQuits3.app", excluded: []))
    precondition(allowedApp(bundleID: "com.apple.Safari", path: "/System/Cryptexes/App/System/Applications/Safari.app", excluded: []))
    let click = PendingClick(frame: CGRect(x: -100, y: 50, width: 14, height: 14), timestamp: 10)
    precondition(click.releasedInside(at: CGPoint(x: -95, y: 55), timestamp: 11))
    precondition(!click.releasedInside(at: CGPoint(x: -70, y: 55), timestamp: 11))
    precondition(!click.releasedInside(at: CGPoint(x: -95, y: 55), timestamp: 9))
    precondition(!isCloseButton(AXUIElementCreateSystemWide()))
    precondition(Bundle.main.url(forResource: "RedQuits3", withExtension: "icns") != nil, "App icon missing from bundle")
    precondition(NSImage(named: "StatusIcon") != nil, "Menu-bar icon missing from bundle")
    print("selftest OK (no user settings changed)")
}
