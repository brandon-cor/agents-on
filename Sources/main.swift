import Cocoa
import Darwin

func parseSleepDisabled(_ output: String) -> Bool? {
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.first == "SleepDisabled", parts.count > 1 {
            return parts[1] == "1"
        }
    }
    // macOS omits SleepDisabled until someone explicitly configures it.
    return output.contains("Currently in use:") ? false : nil
}

func sleepDisabled() -> Bool? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
    return parseSleepDisabled(output)
}

// own only our caffeinate process; -w releases its assertions if this app exits.
class CaffeineSession {
    var process: Process?
    var isRunning: Bool { process?.isRunning == true }
    func update(enabled: Bool) {
        if enabled && !isRunning {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            child.arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            do { try child.run(); process = child } catch { process = nil }
        } else if !enabled, let child = process {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            process = nil
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var busy = false
    var current: Bool?
    let caffeine = CaffeineSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp])
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(requestRefresh), name: Notification.Name("io.github.brandon-cor.agents-on.refresh"), object: nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func setIndicator(enabled: Bool?) {
        let active = enabled == true
        let light = NSImage(size: NSSize(width: 16, height: 18), flipped: false) { _ in
            if active {
                NSColor(srgbRed: 0.1, green: 1.0, blue: 0.25, alpha: 0.15).setFill()
                NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 14, height: 14)).fill()
                NSColor(srgbRed: 0.1, green: 1.0, blue: 0.25, alpha: 0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: 3, width: 12, height: 12)).fill()
            }
            let circle = NSBezierPath(ovalIn: NSRect(x: 3, y: 4, width: 10, height: 10))
            (active ? NSColor(srgbRed: 0.15, green: 1.0, blue: 0.3, alpha: 1) : NSColor.white.withAlphaComponent(0.45)).setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        light.isTemplate = false
        statusItem.button?.image = light
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = enabled == nil ? "agents ?" : (active ? "agents on" : "agents off")
    }

    @objc func requestRefresh() { refresh() }

    func applicationWillTerminate(_ notification: Notification) { caffeine.update(enabled: false) }

    func refresh() {
        guard !busy else { return }
        current = sleepDisabled()
        if let enabled = current {
            caffeine.update(enabled: enabled)
            setIndicator(enabled: enabled)
            statusItem.button?.toolTip = enabled ? "Click to turn agents off" : "Click to turn agents on"
            if enabled && !caffeine.isRunning {
                statusItem.button?.title = "agents on !"
                statusItem.button?.toolTip = "Sleep disabled, but caffeinate could not start. Click to turn off."
            }
        } else {
            setIndicator(enabled: nil)
            statusItem.button?.toolTip = "Agents On: unable to read sleep setting"
        }
    }

    @objc func toggle() {
        guard !busy else { return }
        guard let enabled = sleepDisabled() else {
            showError("Unable to read the current sleep setting.")
            return
        }
        change(to: !enabled)
    }
    func change(to enabled: Bool) {
        guard !busy else { return }
        busy = true
        statusItem.button?.isEnabled = false
        let value = enabled ? "1" : "0"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = FileHandle.nullDevice
            var failure: String?
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 { failure = String(data: data, encoding: .utf8) ?? "Could not change sleep setting." }
            } catch { failure = error.localizedDescription }
            let message = failure
            DispatchQueue.main.async {
                self.busy = false
                self.statusItem.button?.isEnabled = true
                self.refresh()
                if let message = message, !message.contains("-128") {
                    self.showError(message)
                } else if message == nil && self.current != enabled {
                    self.showError("The requested sleep setting could not be verified.")
                }
            }
        }
    }
    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Agents On could not change sleep mode"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--refresh") {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.brandon-cor.agents-on.refresh"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if CommandLine.arguments.contains("--status") {
    if let enabled = sleepDisabled() {
        print(enabled ? "Keep awake ON (SleepDisabled 1)" : "Keep awake OFF (SleepDisabled 0)")
        exit(0)
    }
    fputs("Unable to read SleepDisabled\n", stderr)
    exit(1)
}
let support = NSHomeDirectory() + "/Library/Application Support/Agents On"
do { try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true) }
catch { fputs("Could not create app support directory: \(error)\n", stderr); exit(1) }
let lockPath = support + "/app.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
