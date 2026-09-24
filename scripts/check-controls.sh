#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed '/^\/\/ a live request\/response/,$d' Sources/main.swift > "$work/controls.swift"
cat >> "$work/controls.swift" <<'SWIFT'
// check click dispatch and timer presentation without changing power settings.
class ControlCheck: AppDelegate {
    var toggles = 0
    var menus = 0
    var testDeadline: Date?
    override var deadline: Date? {
        get { testDeadline }
        set { testDeadline = newValue }
    }
    override func refresh() { setIndicator(enabled: false) }
    override func toggle() { toggles += 1 }
    override func showTimers(_ sender: NSButton) { menus += 1 }
}
let app = NSApplication.shared
let check = ControlCheck()
check.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
check.timer?.invalidate()
check.compact = false
check.handleClick(.leftMouseUp)
precondition(check.toggles == 1 && check.menus == 0)
check.handleClick(.rightMouseUp)
precondition(check.toggles == 1 && check.menus == 1)
check.deadline = Date().addingTimeInterval(1800)
check.setIndicator(enabled: true)
precondition(check.statusItem.button!.title == "agents on")
precondition(check.timerMenu().items.first!.title.contains("30m 00s remaining"))
let menu = check.timerMenu()
precondition(menu.items.filter { $0.action != nil }.map { $0.title } == ["30 minutes", "1 hour", "3 hours", "Custom duration…", "Show menu bar text"])
check.menuWillOpen(menu)
check.deadline = Date().addingTimeInterval(1799)
let until = Date().addingTimeInterval(0.35)
while Date() < until { RunLoop.main.run(mode: .eventTracking, before: until) }
precondition(menu.items.first!.title.contains("29m 59s"))
check.menuDidClose(menu)
precondition(check.menuTimer == nil)
precondition(customSeconds(hours: "1", minutes: "30") == 5400)
precondition(customSeconds(hours: "", minutes: "30") == 1800)
precondition(customSeconds(hours: "0", minutes: "0") == nil)
precondition(customSeconds(hours: "nan", minutes: "5") == nil)
precondition(customSeconds(hours: "6", minutes: "0") == 21600)
let savedCompact = UserDefaults.standard.object(forKey: "compactIndicator")
check.setCompact(true)
precondition(check.statusItem.button!.title.isEmpty)
precondition(check.timerMenu().items.last!.state == .off)
check.toggleMenuBarText()
precondition(check.statusItem.button!.title == "agents off")
precondition(check.timerMenu().items.last!.state == .on)
precondition(!UserDefaults.standard.bool(forKey: "compactIndicator"))
UserDefaults.standard.set(savedCompact, forKey: "compactIndicator")
check.customDuration()
precondition(check.hoursInput.stringValue == "0" && check.minutesInput.stringValue == "0")
check.cancelDuration()
check.setIndicator(enabled: false)
precondition(check.statusItem.button!.title == "agents off")
precondition(check.statusItem.button!.image != nil)
NSStatusBar.system.removeStatusItem(check.statusItem)
print("Left-click toggle, right-click menu, lowercase labels, and dropdown-only timer verified.")
SWIFT
/usr/bin/swiftc -target "$(uname -m)-apple-macos14.0" "$work/controls.swift" -o "$work/controls" -framework Cocoa
"$work/controls"
