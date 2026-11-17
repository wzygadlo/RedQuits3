import AppKit

// Two disposable windows: closing one normally leaves this fixture running.
// --child-window adds a Settings-style window, which should stop RedQuits3 from quitting the fixture.
final class Fixture: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        for index in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 300 + index * 80, y: 300 + index * 80, width: 440, height: 220),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "RedQuits3 disposable test \(index + 1)"
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        if CommandLine.arguments.contains("--child-window") {
            // No minimize button, like most Settings windows.
            let child = NSWindow(contentRect: NSRect(x: 860, y: 300, width: 300, height: 160),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            child.title = "RedQuits3 disposable child"
            child.isReleasedWhenClosed = false
            child.orderFront(nil)
            windows.append(child)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard CommandLine.arguments.count >= 2, let primaryScreen = NSScreen.screens.first else {
            fatalError("Fixture requires an output path and a screen")
        }
        // Close-button centers in global top-left-origin coordinates, the space CGEvent and AX use.
        func closeButtonCenter(_ window: NSWindow) -> CGPoint {
            guard let button = window.standardWindowButton(.closeButton) else { fatalError("Fixture window has no close button") }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            return CGPoint(x: rect.midX, y: primaryScreen.frame.maxY - rect.midY)
        }
        let main = closeButtonCenter(windows[1])
        var output: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                     "x": main.x, "y": main.y, "windows": windows.count]
        if windows.count > 2 {
            let child = closeButtonCenter(windows[2])
            output["childX"] = child.x
            output["childY"] = child.y
        }
        do {
            try JSONSerialization.data(withJSONObject: output).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        } catch { fatalError("Cannot write fixture coordinates: \(error)") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CommandLine.arguments.contains("--refuse-quit") {
            NSLog("FIXTURE: quit refused (simulates cancelling a save prompt)")
            return .terminateCancel
        }
        NSLog("FIXTURE: quit accepted; visible windows remaining=%d", windows.filter(\.isVisible).count)
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = Fixture()
app.delegate = delegate
app.run()
