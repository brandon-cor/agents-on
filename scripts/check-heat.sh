#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed '/^\/\/ a live request\/response/,$d' Sources/main.swift > "$work/heat-check.swift"
cat >> "$work/heat-check.swift" <<'SWIFT'
// simulate readings and command results without heating a Mac or changing pmset.
class HeatCheck: AppDelegate {
    var simulatedState: ProcessInfo.ThermalState = .nominal
    var simulatedSleep: Bool? = false
    var commands: [Bool] = []
    var assertionsActive = false
    var commandFails = false
    var holdCommand = false
    var heldCompletion: ((String?) -> Void)?
    var errors: [String] = []
    override func readThermalState() -> ProcessInfo.ThermalState { simulatedState }
    override func readSleepState() -> Bool? { simulatedSleep }
    override func updateCaffeine(enabled: Bool) { assertionsActive = enabled }
    override func showError(_ message: String) { errors.append(message) }
    override func setSleepState(_ enabled: Bool, completion: @escaping (String?) -> Void) {
        commands.append(enabled)
        if holdCommand { heldCompletion = completion; return }
        if !commandFails { simulatedSleep = enabled }
        completion(commandFails ? "Simulated permission failure" : nil)
    }
    func reset(on: Bool = true, state: ProcessInfo.ThermalState = .nominal) {
        simulatedSleep = on
        simulatedState = state
        current = on
        commands = []
        errors = []
        commandFails = false
        holdCommand = false
        heldCompletion = nil
        assertionsActive = on
        heatProtection = true
        heatShutdownPending = false
        turnedOffForHeat = false
        heatShutdownFailed = false
        heatRetryAfter = .distantPast
        expiryFailed = false
        retryAfter = .distantPast
        deadline = on ? Date().addingTimeInterval(3600) : nil
    }
}
let app = NSApplication.shared
let defaults = UserDefaults.standard
let keys = ["heatProtection", "heatShutdownPending", "turnedOffForHeat", "awakeUntil"]
let saved = keys.map { ($0, defaults.object(forKey: $0)) }
defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
let check = HeatCheck()
check.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
check.compact = false
for state in [ProcessInfo.ThermalState.nominal, .fair] {
    check.reset(state: state)
    check.refresh()
    precondition(check.commands.isEmpty && check.assertionsActive && check.deadline != nil)
}
for state in [ProcessInfo.ThermalState.serious, .critical] {
    check.reset(state: state)
    check.refresh()
    precondition(check.commands == [false])
    precondition(check.simulatedSleep == false && !check.assertionsActive && check.deadline == nil)
    precondition(check.turnedOffForHeat && !check.heatShutdownPending)
    precondition(check.statusItem.button!.title == "agents off")
    precondition(check.timerMenu().items.first!.title == "Turned off because of heat")
    check.simulatedState = .nominal
    check.refresh()
    precondition(check.commands == [false], "cooling must never resume keep-awake")
}
check.reset(state: .serious)
check.heatProtection = false
check.refresh()
precondition(check.commands.isEmpty && check.assertionsActive)
check.toggleHeatProtection()
precondition(check.commands == [false] && check.turnedOffForHeat)
let settings = check.timerMenu().items.filter { $0.action != nil }
precondition(settings.suffix(2).map { $0.title } == ["Show menu bar text", "Turn off if it gets too hot"])
precondition(settings.last!.state == .on)
check.reset(on: false, state: .critical)
check.change(to: true, seconds: 60)
precondition(check.commands.isEmpty && check.errors.count == 1)
check.reset(state: .serious)
check.commandFails = true
check.refresh()
precondition(check.heatShutdownPending && check.heatShutdownFailed && !check.assertionsActive)
precondition(check.deadline == nil && !check.turnedOffForHeat)
check.refresh()
precondition(check.commands == [false], "failed shutdowns must back off")
check.simulatedState = .nominal
check.heatProtection = false
check.commandFails = false
check.heatRetryAfter = .distantPast
check.refresh()
precondition(check.commands == [false, false] && check.turnedOffForHeat)
check.reset(on: false)
check.holdCommand = true
check.change(to: true, seconds: 60)
check.simulatedState = .serious
check.refresh()
precondition(check.heatShutdownPending)
check.simulatedState = .nominal
check.simulatedSleep = true
check.holdCommand = false
check.heldCompletion?(nil)
precondition(check.commands == [true, false] && check.turnedOffForHeat && check.deadline == nil)
check.reset()
check.heatShutdownPending = true
let restarted = HeatCheck()
restarted.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
restarted.simulatedSleep = true
precondition(restarted.heatShutdownPending)
restarted.refresh()
precondition(restarted.commands == [false] && restarted.turnedOffForHeat)
restarted.simulatedState = .nominal
restarted.change(to: true)
precondition(!restarted.turnedOffForHeat && restarted.simulatedSleep == true)
NSStatusBar.system.removeStatusItem(check.statusItem)
NSStatusBar.system.removeStatusItem(restarted.statusItem)
print("Thermal cutoff, disabled mode, hot start rejection, retries, in-flight race, restart recovery, and manual restart verified.")
SWIFT
/usr/bin/swiftc -target "$(uname -m)-apple-macos14.0" "$work/heat-check.swift" -o "$work/heat-check" -framework Cocoa
"$work/heat-check"
