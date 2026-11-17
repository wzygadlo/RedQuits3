import AppKit
import ApplicationServices
import Darwin

let debugLogging = ProcessInfo.processInfo.environment["RQ3_DEBUG"] != nil

struct Config: Codable {
    var enabled = true
    var excludedApps: [String] = ["com.apple.finder"]
}

extension Config {
    // Keys missing from a hand-edited file keep their defaults instead of invalidating it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? excludedApps
    }
}

struct UnreadableSettings: LocalizedError {
    var errorDescription: String? {
        "\(Store.url.path) couldn't be read, so it was left unchanged. Fix or delete it, then relaunch RedQuits3."
    }
}

enum Store {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RedQuits3", isDirectory: true)
    static let url = dir.appendingPathComponent("config.json")
    private(set) static var loadFailed = false
    static var config: Config = {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            NSLog("RQ3: invalid settings; auto-quit disabled: %@", String(describing: error))
            loadFailed = true
            return Config(enabled: false)
        }
    }()

    static func save() throws {
        // Overwriting a file that failed to load would silently drop the user's exclusions.
        guard !loadFailed else { throw UnreadableSettings() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
    }
}

func allowedApp(bundleID: String, path: String, excluded: [String]) -> Bool {
    !path.hasPrefix("/System/Library/") && !excluded.contains(bundleID)
        && bundleID != "com.wzygadlo.RedQuits3"
}

func eligible(_ app: NSRunningApplication) -> Bool {
    guard !app.isTerminated, app.activationPolicy == .regular,
          app.processIdentifier > 1, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
          let id = app.bundleIdentifier, let path = app.bundleURL?.path else { return false }
    return allowedApp(bundleID: id, path: path, excluded: Store.config.excludedApps)
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

struct WindowTraits {
    var subrole: String?
    var modal = false
    var minimized = false
    var fullScreen = false
    var closable = false
    var closeEnabled = false
    var minimizable = false

    /// Dialogs, sheets, panels, palettes, and Settings or About windows: anything but a regular app window.
    var isChild: Bool {
        guard let subrole else { return true }   // unreadable: assume the worst
        if modal { return true }
        if minimized { return false }
        guard closable else { return false }     // borderless helpers, popups and overlays
        if !closeEnabled { return true }         // a sheet is open on it
        // Settings and About windows are standard windows whose minimize button is disabled.
        return !(subrole == kAXStandardWindowSubrole && (minimizable || fullScreen))
    }
}

func windowTraits(_ window: AXUIElement) -> WindowTraits {
    let close = axElement(window, kAXCloseButtonAttribute)
    let minimize = axElement(window, kAXMinimizeButtonAttribute)
    return WindowTraits(subrole: axValue(window, kAXSubroleAttribute) as? String,
                        modal: axValue(window, kAXModalAttribute) as? Bool == true,
                        minimized: axValue(window, kAXMinimizedAttribute) as? Bool == true,
                        fullScreen: axValue(window, "AXFullScreen") as? Bool == true,
                        closable: close != nil,
                        closeEnabled: close.flatMap { axValue($0, kAXEnabledAttribute) as? Bool } == true,
                        minimizable: minimize.flatMap { axValue($0, kAXEnabledAttribute) as? Bool } == true)
}

/// The app whose title-bar close button is under `point` (global, top-left origin) and that button's frame,
/// when releasing there should quit the app.
func closeButtonTarget(at point: CGPoint) -> (app: NSRunningApplication, frame: CGRect)? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(hit, &pid) == .success,
          let app = NSRunningApplication(processIdentifier: pid), eligible(app) else { return nil }

    // Only the window's own title-bar button counts, not every element that calls itself a close button.
    let window = axValue(hit, kAXRoleAttribute) as? String == kAXWindowRole ? hit : axElement(hit, kAXWindowAttribute)
    guard let window, let button = axElement(window, kAXCloseButtonAttribute),
          axValue(button, kAXEnabledAttribute) as? Bool == true,
          let frame = buttonFrame(button), frame.contains(point) else {
        if debugLogging { NSLog("RQ3: mouse-down on %@; not inside its AX close button", app.localizedName ?? "?") }
        return nil
    }

    // While the app has a child window open, including the one being closed, only that window closes.
    guard let windows = axValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement],
          !([window] + windows).contains(where: { windowTraits($0).isChild }) else {
        if debugLogging { NSLog("RQ3: %@ has a child window open (or unreadable windows); not quitting", app.localizedName ?? "?") }
        return nil
    }
    return (app, frame)
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
        // A hung app would otherwise stall each click for AX's default 6-second timeout.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
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

    private func handleMouse(_ event: NSEvent) {
        guard Store.config.enabled, AXIsProcessTrusted(), let point = event.cgEvent?.location else {
            target = nil
            return
        }
        if event.type == .leftMouseDown {
            // Capture BEFORE mouse-up: afterwards the closed window may no longer exist.
            target = closeButtonTarget(at: point).map {
                (app: $0.app, click: PendingClick(frame: $0.frame, timestamp: event.timestamp))
            }
            if debugLogging, let target { NSLog("RQ3: captured %@ close button on mouse-down", target.app.localizedName ?? "?") }
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

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

func selfTest() throws {
    // Throwing rather than trapping names the failed check, even in the optimized build.
    func check(_ condition: Bool, _ expectation: String) throws {
        if !condition { throw SelfTestFailure(description: expectation) }
    }
    let sample = Config(enabled: false, excludedApps: ["test.bundle"])
    let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(sample))
    try check(!decoded.enabled && decoded.excludedApps == ["test.bundle"], "settings survive saving and loading")
    let partial = try JSONDecoder().decode(Config.self, from: Data(#"{"excludedApps": []}"#.utf8))
    try check(partial.enabled && partial.excludedApps.isEmpty, "missing settings keep their defaults")
    try check((try? JSONDecoder().decode(Config.self, from: Data(#"{"enabled": "yes"}"#.utf8))) == nil,
              "a mistyped setting is rejected")

    try check(!allowedApp(bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app", excluded: []),
              "Finder is protected")
    try check(!allowedApp(bundleID: "test.bundle", path: "/Applications/Test.app", excluded: ["test.bundle"]),
              "excluded apps are left alone")
    try check(!allowedApp(bundleID: "com.wzygadlo.RedQuits3", path: "/Applications/RedQuits3.app", excluded: []),
              "RedQuits3 never quits itself")
    try check(allowedApp(bundleID: "com.apple.Safari", path: "/System/Cryptexes/App/System/Applications/Safari.app", excluded: []),
              "Safari can be quit")

    let click = PendingClick(frame: CGRect(x: -100, y: 50, width: 14, height: 14), timestamp: 10)
    try check(click.releasedInside(at: CGPoint(x: -95, y: 55), timestamp: 11), "a release inside the button counts")
    try check(!click.releasedInside(at: CGPoint(x: -70, y: 55), timestamp: 11), "a release outside the button doesn't count")
    try check(!click.releasedInside(at: CGPoint(x: -95, y: 55), timestamp: 9), "a release before the press doesn't count")

    let document = WindowTraits(subrole: kAXStandardWindowSubrole, closable: true, closeEnabled: true, minimizable: true)
    var settings = document
    settings.minimizable = false
    var fullScreen = settings
    fullScreen.fullScreen = true
    var showingSheet = document
    showingSheet.closeEnabled = false
    var minimized = settings
    minimized.minimized = true
    try check(!document.isChild, "a regular window isn't a child window")
    try check(settings.isChild, "a Settings-style window without minimize is a child window")
    try check(!fullScreen.isChild, "a full-screen window isn't a child window")
    try check(showingSheet.isChild, "a window showing a sheet counts as a child window")
    try check(!minimized.isChild, "a minimized window isn't a child window")
    try check(WindowTraits(subrole: kAXDialogSubrole, closable: true, closeEnabled: true).isChild, "a dialog is a child window")
    try check(WindowTraits(subrole: kAXFloatingWindowSubrole, closable: true, closeEnabled: true).isChild,
              "a floating panel is a child window")
    try check(WindowTraits(subrole: kAXDialogSubrole, modal: true).isChild, "a modal alert is a child window")
    try check(!WindowTraits(subrole: kAXUnknownSubrole).isChild, "a borderless helper window is ignored")
    try check(windowTraits(AXUIElementCreateSystemWide()).isChild, "an unreadable window counts as a child window")

    try check(Bundle.main.url(forResource: "RedQuits3", withExtension: "icns") != nil, "the app icon is in the bundle")
    try check(NSImage(named: "StatusIcon") != nil, "the menu-bar icon is in the bundle")
    print("selftest OK (no user settings changed)")
}
