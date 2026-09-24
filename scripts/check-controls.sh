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
precondition(check.timerMenu().items.first!.title.contains("30m remaining"))
check.setIndicator(enabled: false)
precondition(check.statusItem.button!.title == "agents off")
precondition(check.statusItem.button!.image != nil)
NSStatusBar.system.removeStatusItem(check.statusItem)
print("Left-click toggle, right-click menu, lowercase labels, and dropdown-only timer verified.")
SWIFT
/usr/bin/swiftc -target "$(uname -m)-apple-macos14.0" "$work/controls.swift" -o "$work/controls" -framework Cocoa
"$work/controls"
