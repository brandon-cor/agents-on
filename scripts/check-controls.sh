#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed '/^\/\/ a live request\/response/,$d' Sources/main.swift > "$work/controls.swift"
cat >> "$work/controls.swift" <<'SWIFT'
// exercise real appkit hit testing and button dispatch without changing power settings.
class ControlCheck: AppDelegate {
    var toggles = 0
    var menus = 0
    override func refresh() { setIndicator(enabled: false) }
    override func toggle() { toggles += 1 }
    override func showTimers(_ sender: NSButton) { menus += 1 }
}
let app = NSApplication.shared
let check = ControlCheck()
check.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
check.timer?.invalidate()
let container = check.statusItem.button!
check.compact = false
check.setIndicator(enabled: false)
precondition(container.hitTest(NSPoint(x: 14, y: 10)) === check.powerButton)
precondition(container.hitTest(NSPoint(x: 40, y: 10)) === check.textButton)
check.textButton.performClick(nil)
precondition(check.menus == 1 && check.toggles == 0)
check.powerButton.performClick(nil)
precondition(check.menus == 1 && check.toggles == 1)
let event = NSEvent.mouseEvent(with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
check.textButton.rightMouseUp(with: event)
check.powerButton.rightMouseUp(with: event)
precondition(check.menus == 1 && check.toggles == 1)
check.textButton.menuOpen = true
check.textButton.displayIfNeeded()
check.textButton.menuOpen = false
precondition(check.powerButton.image != nil)
NSStatusBar.system.removeStatusItem(check.statusItem)
print("Split hit areas, left-click dispatch, and ignored right-clicks verified.")
SWIFT
/usr/bin/swiftc -target "$(uname -m)-apple-macos14.0" "$work/controls.swift" -o "$work/controls" -framework Cocoa
"$work/controls"
