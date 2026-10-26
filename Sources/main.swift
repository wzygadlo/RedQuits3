import AppKit

if CommandLine.arguments.contains("--selftest") {
    do {
        try selfTest()
        exit(0)
    } catch {
        fputs("selftest failed: \(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
