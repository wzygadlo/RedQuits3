import AppKit

// Two disposable windows: closing one normally leaves this fixture running.
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
        NSApp.activate(ignoringOtherApps: true)
        guard CommandLine.arguments.count >= 2,
              let window = windows.last, let button = window.standardWindowButton(.closeButton),
              let primaryScreen = NSScreen.screens.first else { fatalError("Fixture requires an output path and a screen") }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let output: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                     "x": rect.midX, "y": primaryScreen.frame.maxY - rect.midY,
                                     "windows": windows.count]
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
