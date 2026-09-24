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

func durationLabel(_ seconds: Double) -> String {
    let minutes = max(1, Int(ceil(seconds / 60)))
    let hours = minutes / 60
    let remainder = minutes % 60
    return [hours > 0 ? "\(hours)H" : "", remainder > 0 ? "\(remainder)M" : ""].filter { !$0.isEmpty }.joined(separator: " ")
}

// separate buttons keep the power hit area independent of the timer menu.
class IndicatorButton: NSButton {
    var menuOpen = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true || menuOpen
        if pressed {
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        if pressed {
            let transform = AffineTransform(translationByX: 0, byY: -1)
            (transform as NSAffineTransform).concat()
        }
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let powerButton = IndicatorButton()
    let textButton = IndicatorButton()
    var selectedDuration: Double? {
        get { UserDefaults.standard.object(forKey: "awakeDuration") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "awakeDuration") }
    }
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
        for button in [powerButton, textButton] {
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.font = .menuBarFont(ofSize: 0)
            button.target = self
            button.sendAction(on: [.leftMouseUp])
            statusItem.button?.addSubview(button)
        }
        powerButton.action = #selector(toggle)
        textButton.action = #selector(showTimers(_:))
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(requestRefresh(_:)), name: Notification.Name("io.github.brandon-cor.agents-on.refresh"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(uiRequest(_:)), name: Notification.Name("io.github.brandon-cor.agents-on.ui-request"), object: nil)
        refresh()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func setIndicator(enabled: Bool?) {
        let active = enabled == true
        let light = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            if active {
                NSColor(srgbRed: 0.1, green: 1, blue: 0.25, alpha: 0.18).setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 18, height: 18)).fill()
            }
            (active ? NSColor(srgbRed: 0.15, green: 1, blue: 0.3, alpha: 1) : NSColor.labelColor.withAlphaComponent(0.5)).setStroke()
            let glyph = NSBezierPath()
            glyph.lineWidth = 1.8
            glyph.lineCapStyle = .round
            glyph.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 5.5, startAngle: 55, endAngle: 125, clockwise: true)
            glyph.move(to: NSPoint(x: 9, y: 9))
            glyph.line(to: NSPoint(x: 9, y: 15))
            glyph.stroke()
            return true
        }
        light.isTemplate = false
        powerButton.image = light
        powerButton.title = ""
        powerButton.setAccessibilityLabel(active ? "Turn agents off" : "Turn agents on indefinitely")
        powerButton.toolTip = active ? "Turn agents off" : "Turn agents on indefinitely"
        var label = enabled == nil ? "Agents ?" : (active ? "Agents On" : "Agents Off")
        if active, let end = deadline {
            label += "-" + durationLabel(selectedDuration ?? max(1, end.timeIntervalSinceNow))
        }
        if expiryFailed || (active && !caffeine.isRunning) { label += " !" }
        textButton.title = label
        textButton.setAccessibilityLabel(label + ", timer options")
        textButton.toolTip = "Choose a keep-awake duration"
        let height = NSStatusBar.system.thickness
        let width = ceil((label as NSString).size(withAttributes: [.font: textButton.font!]).width) + 16
        statusItem.length = 28 + (compact ? 0 : width)
        powerButton.frame = NSRect(x: 0, y: 0, width: 28, height: height)
        textButton.frame = NSRect(x: 28, y: 0, width: width, height: height)
        textButton.isHidden = compact
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
            "label": textButton.title,
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
        let body = NSTextField(wrappingLabelWithString: "Look near the clock for the power icon and ‘Agents On’ / ‘Agents Off’. Click the power icon to toggle. Click the text for timers.\n\nIf it is missing, move your pointer to the top edge and check any menu bar manager. On a crowded menu bar, try the compact light below. Hold Command and drag the light to reposition it.")
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
        if notification.userInfo?["cancelTimer"] as? Bool == true { deadline = nil; selectedDuration = nil; expiryFailed = false }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) { caffeine.update(enabled: false) }

    func refresh() {
        guard !busy else { return }
        current = sleepDisabled()
        if let enabled = current {
            if !enabled { if deadline != nil { deadline = nil }; selectedDuration = nil; expiryFailed = false }
            if enabled, let end = deadline, end <= Date(), Date() >= retryAfter {
                change(to: false, expiring: true)
                return
            }
            caffeine.update(enabled: enabled)
            setIndicator(enabled: enabled)
            textButton.toolTip = "Click the text for timer options; click the power icon to toggle"
            if enabled, let end = deadline {
                textButton.toolTip = "agents on — \(max(1, Int(ceil(end.timeIntervalSinceNow / 60)))) min remaining. Click for timer options."
            }
            if expiryFailed {
                textButton.toolTip = "Timer ended; sleep restoration failed. Retrying every 30 seconds."
            }
            if enabled && !caffeine.isRunning {
                textButton.toolTip = "Sleep disabled, but caffeinate could not start. Click to turn off."
            }
        } else {
            setIndicator(enabled: nil)
            textButton.toolTip = "Agents On: unable to read sleep setting"
        }
    }

    @objc func showTimers(_ sender: NSButton) {
        let indicator = sender as? IndicatorButton
        indicator?.menuOpen = true
        sender.displayIfNeeded()
        defer { indicator?.menuOpen = false }
        timerMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    func timerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let end = deadline {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let item = NSMenuItem(title: "Turns off at " + formatter.string(from: end), action: nil, keyEquivalent: "")
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
        for (title, action) in [("Custom duration…", #selector(customDuration)), ("Until I turn it off", #selector(unlimited)), ("Turn off now", #selector(stopNow))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = !busy
            menu.addItem(item)
        }
        return menu
    }

    @objc func preset(_ sender: NSMenuItem) { change(to: true, seconds: Double(sender.tag) * 60) }
    @objc func unlimited() { change(to: true) }
    @objc func stopNow() { change(to: false) }
    @objc func customDuration() {
        let alert = NSAlert()
        alert.messageText = "Keep agents on for how long?"
        alert.informativeText = "Enter minutes (90 = 1½ hours). Decimals are allowed. Maximum: 525,600 minutes."
        let input = NSTextField(string: "90")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        input.setAccessibilityLabel("Duration in minutes")
        alert.accessoryView = input
        alert.addButton(withTitle: "Start timer")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let seconds = durationSeconds(input.stringValue) else {
            showError("Enter a positive number of minutes up to 525,600.")
            return
        }
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
        powerButton.isEnabled = false
        textButton.isEnabled = false
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
                self.powerButton.isEnabled = true
                self.textButton.isEnabled = true
                if message == nil && sleepDisabled() == enabled {
                    self.deadline = enabled ? seconds.map { Date().addingTimeInterval($0) } : nil
                    self.selectedDuration = enabled ? seconds : nil
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
