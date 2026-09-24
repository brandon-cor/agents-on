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

func durationSeconds(_ text: String) -> Double? {
    guard let minutes = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), minutes.isFinite, minutes > 0, minutes <= 525600 else { return nil }
    return minutes * 60
}

func countdownLabel(_ seconds: Double) -> String {
    let total = max(0, Int(ceil(seconds)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return (hours > 0 ? "\(hours)h " : "") + "\(minutes)m " + String(format: "%02ds", seconds)
}

func customSeconds(hours: String, minutes: String) -> Double? {
    func number(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? 0 : Double(text)
    }
    guard let h = number(hours), let m = number(minutes), h.isFinite, m.isFinite, h >= 0, m >= 0 else { return nil }
    return durationSeconds(String(h * 60 + m))
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    var statusItem: NSStatusItem!
    var menuTimer: Timer?
    var countdownItem: NSMenuItem?
    var durationWindow: NSPanel?
    let hoursInput = NSTextField(string: "0")
    let minutesInput = NSTextField(string: "0")
    let durationError = NSTextField(labelWithString: "")
    var timer: Timer?
    var busy = false
    var deadline: Date? {
        get { UserDefaults.standard.object(forKey: "awakeUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "awakeUntil") }
    }
    var retryAfter = Date.distantPast
    var expiryFailed = false
    var current: Bool?
    let caffeine = CaffeineSession()
    var helpWindow: NSWindow?
    var compact = UserDefaults.standard.bool(forKey: "compactIndicator")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "agents-on-indicator"
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(indicatorClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(requestRefresh(_:)), name: Notification.Name("io.github.brandon-cor.agents-on.refresh"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(uiRequest(_:)), name: Notification.Name("io.github.brandon-cor.agents-on.ui-request"), object: nil)
        refresh()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
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
        statusItem.button?.title = compact ? "" : (enabled == nil ? "agents ?" : (active ? "agents on" : "agents off"))
        statusItem.button?.setAccessibilityLabel(enabled == true ? "agents on" : "agents off")
    }

    @objc func uiRequest(_ notification: Notification) {
        guard let requestID = notification.object as? String else { return }
        if notification.userInfo?["show"] as? Bool == true {
            statusItem.isVisible = true
            showHelp()
        }
        refresh()
        let frame = statusItem.button?.window?.frame ?? .zero
        let onScreen = !frame.isEmpty && NSScreen.screens.contains { $0.frame.intersects(frame) }
        let response: [String: Any] = [
            "requestID": requestID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "itemCreated": statusItem.button != nil,
            "itemEnabled": statusItem.isVisible,
            "frameOnScreen": onScreen,
            "label": statusItem.button?.title ?? "",
            "compact": compact,
            "caffeinateRunning": caffeine.isRunning,
            "awakeUntil": deadline.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Agents On/ui-status.json"), options: .atomic)
        } catch { fputs("Unable to write UI status: \(error)\n", stderr) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.isVisible = true
        showHelp()
        return true
    }

    @objc func changeCompact(_ sender: NSButton) {
        compact = sender.state == .on
        UserDefaults.standard.set(compact, forKey: "compactIndicator")
        refresh()
    }

    func showHelp() {
        if let window = helpWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Agents On"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Your menu bar toggle is running")
        heading.font = .boldSystemFont(ofSize: 21)
        heading.frame = NSRect(x: 24, y: 223, width: 452, height: 30)
        let body = NSTextField(wrappingLabelWithString: "Look near the clock for the green or gray light and ‘agents on’ / ‘agents off’. Left-click to toggle; right-click for timers.\n\nIf it is missing, move your pointer to the top edge and check any menu bar manager. On a crowded menu bar, try the compact light below. Hold Command and drag the light to reposition it.")
        body.font = .systemFont(ofSize: 14)
        body.frame = NSRect(x: 24, y: 88, width: 452, height: 127)
        let checkbox = NSButton(checkboxWithTitle: "Compact light only (fits a crowded menu bar)", target: self, action: #selector(changeCompact(_:)))
        checkbox.state = compact ? .on : .off
        checkbox.frame = NSRect(x: 24, y: 48, width: 452, height: 28)
        let footer = NSTextField(labelWithString: "No icon yet? Run agents doctor and share its output.")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.stringValue = "Missing icon? Run agents doctor."
        footer.frame = NSRect(x: 177, y: 17, width: 299, height: 20)
        let timers = NSButton(title: "Timer options…", target: self, action: #selector(showTimers(_:)))
        timers.bezelStyle = .rounded
        timers.frame = NSRect(x: 20, y: 11, width: 149, height: 30)
        for view in [heading, body, checkbox, footer, timers] { window.contentView?.addSubview(view) }
        helpWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func requestRefresh(_ notification: Notification) {
        if notification.userInfo?["cancelTimer"] as? Bool == true { deadline = nil; expiryFailed = false }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) { caffeine.update(enabled: false) }

    func refresh() {
        guard !busy else { return }
        current = sleepDisabled()
        if let enabled = current {
            if !enabled { if deadline != nil { deadline = nil }; expiryFailed = false }
            if enabled, let end = deadline, end <= Date(), Date() >= retryAfter {
                change(to: false, expiring: true)
                return
            }
            caffeine.update(enabled: enabled)
            setIndicator(enabled: enabled)
            statusItem.button?.toolTip = enabled ? "Click to turn agents off" : "Click to turn agents on"
            if enabled, let end = deadline {
                statusItem.button?.toolTip = "agents on — \(max(1, Int(ceil(end.timeIntervalSinceNow / 60)))) min remaining. Right-click for timers."
            }
            if expiryFailed {
                statusItem.button?.title = "agents on !"
                statusItem.button?.toolTip = "Timer ended; sleep restoration failed. Retrying every 30 seconds."
            }
            if enabled && !caffeine.isRunning {
                statusItem.button?.title = "agents on !"
                statusItem.button?.toolTip = "Sleep disabled, but caffeinate could not start. Click to turn off."
            }
        } else {
            setIndicator(enabled: nil)
            statusItem.button?.toolTip = "Agents On: unable to read sleep setting"
        }
    }

    @objc func indicatorClick() {
        handleClick(NSApp.currentEvent?.type ?? .leftMouseUp)
    }

    func handleClick(_ type: NSEvent.EventType) {
        if type == .rightMouseUp, let button = statusItem.button {
            showTimers(button)
        } else if type == .leftMouseUp {
            toggle()
        }
    }

    @objc func showTimers(_ sender: NSButton) {
        timerMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    func timerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        countdownItem = nil
        if let end = deadline {
            let item = NSMenuItem(title: countdownLabel(end.timeIntervalSinceNow) + " remaining", action: nil, keyEquivalent: "")
            countdownItem = item
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for (title, minutes) in [("30 minutes", 30), ("1 hour", 60), ("3 hours", 180)] {
            let item = NSMenuItem(title: title, action: #selector(preset(_:)), keyEquivalent: "")
            item.tag = minutes
            item.target = self
            item.isEnabled = !busy
            menu.addItem(item)
        }
        for (title, action) in [("Custom duration…", #selector(customDuration))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = !busy
            menu.addItem(item)
        }
        return menu
    }

    @objc func preset(_ sender: NSMenuItem) { change(to: true, seconds: Double(sender.tag) * 60) }
    func updateCountdown() {
        countdownItem?.title = deadline.map { countdownLabel($0.timeIntervalSinceNow) + " remaining" } ?? "Timer finished"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTimer?.invalidate()
        updateCountdown()
        let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateCountdown() }
        menuTimer = tick
        // menu tracking uses a separate run-loop mode, so the countdown must run there too.
        RunLoop.main.add(tick, forMode: .eventTracking)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
        countdownItem = nil
    }

    @objc func customDuration() {
        if durationWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 215), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Custom duration"
            panel.isReleasedWhenClosed = false
            let heading = NSTextField(labelWithString: "Keep Agents On for how long?")
            heading.font = .boldSystemFont(ofSize: 18)
            heading.frame = NSRect(x: 24, y: 161, width: 330, height: 28)
            panel.contentView?.addSubview(heading)
            for (field, title, x) in [(hoursInput, "Hours", 24.0), (minutesInput, "Minutes", 194.0)] {
                let label = NSTextField(labelWithString: title)
                label.frame = NSRect(x: x, y: 126, width: 150, height: 20)
                field.frame = NSRect(x: x, y: 91, width: 150, height: 30)
                field.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
                field.setAccessibilityLabel(title)
                field.delegate = self
                panel.contentView?.addSubview(label)
                panel.contentView?.addSubview(field)
            }
            hoursInput.nextKeyView = minutesInput
            durationError.frame = NSRect(x: 24, y: 61, width: 322, height: 20)
            durationError.textColor = .systemRed
            durationError.font = .systemFont(ofSize: 12)
            panel.contentView?.addSubview(durationError)
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDuration))
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"
            cancel.frame = NSRect(x: 130, y: 17, width: 90, height: 32)
            let start = NSButton(title: "Start timer", target: self, action: #selector(startDuration))
            start.bezelStyle = .rounded
            start.keyEquivalent = "\r"
            start.frame = NSRect(x: 225, y: 17, width: 125, height: 32)
            panel.contentView?.addSubview(cancel)
            panel.contentView?.addSubview(start)
            durationWindow = panel
        }
        hoursInput.stringValue = "0"
        minutesInput.stringValue = "0"
        durationError.stringValue = ""
        durationWindow?.center()
        durationWindow?.makeKeyAndOrderFront(nil)
        durationWindow?.makeFirstResponder(hoursInput)
        NSApp.activate(ignoringOtherApps: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            field.stringValue = "0"
        }
    }

    @objc func cancelDuration() { durationWindow?.orderOut(nil) }

    @objc func startDuration() {
        guard let seconds = customSeconds(hours: hoursInput.stringValue, minutes: minutesInput.stringValue) else {
            durationError.stringValue = "Enter a valid duration greater than zero."
            return
        }
        durationWindow?.orderOut(nil)
        change(to: true, seconds: seconds)
    }

    @objc func toggle() {
        guard !busy else { return }
        guard let enabled = sleepDisabled() else {
            showError("Unable to read the current sleep setting.")
            return
        }
        change(to: !enabled)
    }
    func change(to enabled: Bool, seconds: Double? = nil, expiring: Bool = false) {
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
                if message == nil && sleepDisabled() == enabled {
                    self.deadline = enabled ? seconds.map { Date().addingTimeInterval($0) } : nil
                    self.expiryFailed = false
                    self.retryAfter = .distantPast
                } else if expiring {
                    self.expiryFailed = true
                    self.retryAfter = Date().addingTimeInterval(30)
                } else {
                    self.showError(message ?? "The requested sleep setting could not be verified.")
                }
                self.refresh()
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

// a live request/response checks AppKit startup, not just launchd registration.
if CommandLine.arguments.contains("--check-ui") || CommandLine.arguments.contains("--show") {
    let requestID = UUID().uuidString
    let show = CommandLine.arguments.contains("--show")
    let responseURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Agents On/ui-status.json")
    let expectedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    for _ in 0..<20 {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.brandon-cor.agents-on.ui-request"), object: requestID, userInfo: ["show": show], deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.4)
        if let data = try? Data(contentsOf: responseURL),
           let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           response["requestID"] as? String == requestID,
           let pid = response["pid"] as? Int32, kill(pid, 0) == 0 {
            print(String(data: data, encoding: .utf8) ?? "")
            let ready = response["itemCreated"] as? Bool == true && response["itemEnabled"] as? Bool == true && response["version"] as? String == expectedVersion
            exit(ready ? 0 : 1)
        }
    }
    fputs("The menu bar app did not respond. Run agents doctor for startup details.\n", stderr)
    exit(1)
}
if CommandLine.arguments.contains("--refresh") {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.brandon-cor.agents-on.refresh"), object: nil, userInfo: ["cancelTimer": CommandLine.arguments.contains("--cancel-timer")], deliverImmediately: true)
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
