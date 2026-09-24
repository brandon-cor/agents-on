# Agents On

**Keep your Mac awake while your agents work—even with the lid closed.**

![Agents On menu bar states](assets/menu-bar.svg)

Left-click anywhere on the menu bar indicator to toggle **agents on** (bright green light) and **agents off** (dim white light). Turning on starts an indefinite session. Right-click opens timer options without toggling. No password on each toggle.

## Install

For **macOS 14 or newer**, on Apple Silicon or Intel. You need an administrator account. No Homebrew, Xcode, or subscriptions required for the prebuilt release.

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/brandon-cor/agents-on/v0.4.0/install.sh | bash
```

Enter your Mac password once when asked. Typing a password in Terminal does not display characters. The app starts immediately and automatically at login. Your existing sleep setting is preserved.

You can [read the installer](install.sh) first, or [download the release](https://github.com/brandon-cor/agents-on/releases/latest). The installer downloads the app, verifies its SHA-256 checksum and ad-hoc code signature, and installs it in `~/Applications/Agents On.app`. The release is **not Apple-notarized**; browser-downloaded copies may be blocked by Gatekeeper. The installer does not remove quarantine flags or disable Gatekeeper.

## Missing the menu bar icon? (v0.4.0)

Re-run the install command above to update and repair startup. The installer now waits for a response **from the running AppKit app** confirming that its menu bar button exists, instead of treating a registered login job as success. It also re-enables a previously disabled login job and opens a small setup window after the check succeeds.

For an existing installation, open a new terminal and run:

```bash
agents show
```

This starts the app if needed, restores its menu bar item, and opens visibility options. If your menu bar is crowded or has a camera notch, enable **Compact light only**. The default still shows the green/gray light and “agents on/off”; compact mode shows the same clickable light with the label available to accessibility tools and on hover. Check any menu bar manager you use, and move the pointer to the top edge if the bar auto-hides.

If it still does not appear:

```bash
agents doctor
```

Share that output in a [GitHub issue](https://github.com/brandon-cor/agents-on/issues). It reports your macOS version, app version, login-job state, the app's live menu-item response, and recent app startup errors. It does not change sleep settings.

An AppKit response proves that the item was created, **not that macOS has room to show it**. [Apple documents that `isVisible` can remain true when an item is hidden due to insufficient menu bar space](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible).

Opening the ZIP is not the full installation: the Terminal installer also sets up login startup, commands, and the two-command permission rule.

## Timed sessions

Right-click the menu bar indicator to choose **30 minutes**, **1 hour**, **3 hours**, or **Custom duration…**. Custom duration opens a compact, icon-free window with Hours and Minutes fields starting at zero.

Selecting a duration starts keep-awake immediately and replaces any previous countdown. When time runs out, the app restores normal system sleep and stops its caffeinate process. Hover to see minutes remaining; the open menu counts down in seconds.

Left-click the indicator to stop a session or turn on indefinitely. The menu offers only the three presets and Custom duration. While open, it shows a live countdown including seconds. The menu bar stays **agents on/off**. You can also reach the menu from `agents show` → **Timer options…**.

Deadlines persist across app restarts. An overdue timer ends when the app next runs. The app must be running to enforce expiry; if restoring sleep fails, it shows an exclamation mark and retries every 30 seconds. Existing screen-lock settings are unchanged.

## Use

Click the indicator once to toggle. Or open a **new terminal tab** and run:

```bash
sleep on      # keep awake, including with the lid closed
sleep off     # restore normal sleep
sleep status  # report the current system sleep setting
```

`agents on`, `agents off`, and `agents status` also work. Numeric commands such as `sleep 5` still behave normally. Shortcuts are added to the default macOS zsh configuration; other shells can run `~/.local/bin/agents on` directly.

| Mode | What happens |
| --- | --- |
| agents on | Runs `sudo pmset -a disablesleep 1` and starts a managed `caffeinate -di` process. |
| agents off | Runs `sudo pmset -a disablesleep 0` and stops only this app's caffeinate process. |

The `-d` flag keeps the display awake while open; `-i` prevents idle system sleep. The app adds `-w <app-pid>` so caffeinate exits if the app dies. Lid sleep is handled by `pmset`, not caffeinate. The indicator reads the actual `SleepDisabled` setting every second; clicks update it as soon as the command finishes.

**“Agents on” is a keep-awake label.** It does not launch, pause, or stop your AI agents, and it does not remove your screen-lock password. UI automation that needs an unlocked screen may still require one. This is a Mac app, not a Windows or Linux app.

## One-time permission

The installer creates a root-owned, mode `0440` file at `/private/etc/sudoers.d/agents-on-<your-user-id>`. It allows **only your account** to run these exact commands without a password:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

No blanket sudo access is granted. The app never stores your password. `visudo` validates the rule before installation. Uninstalling removes it.

## A few practical details

- Keep your Mac on a ventilated surface. Turn this off before putting it in a bag. Keeping it awake uses battery; there is no automatic battery cutoff.
- `SleepDisabled` is a persistent, system-wide setting. It affects all logged-in users and can remain enabled after a crash or restart. Run `sudo pmset -a disablesleep 0` to restore sleep independently of this app.
- Other keep-awake apps can also affect sleep. Do not run multiple copies of Agents On or another lid-sleep manager together.
- `disablesleep` is an undocumented macOS option. The app is built for macOS 14+, but lid-closed behavior must be checked on your Mac. The initial release's commands and caffeinate lifecycle were tested on Apple Silicon with macOS 27; Intel is cross-compiled, not physically tested.
- If the label shows `agents on !`, sleep is disabled but caffeinate could not start. Click to turn it off and reinstall if it persists.

## Uninstall

```bash
bash "$HOME/Library/Application Support/Agents On/uninstall.sh"
```

Uninstall asks for administrator authorization to remove the permission rule, restores normal system sleep, removes the app and login agent, and removes only its own shell configuration line.

## Build from source

Requires Apple's Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/brandon-cor/agents-on.git
cd agents-on
bash scripts/build.sh
bash install.sh --archive-dir "$PWD/dist"
```

The build creates a universal Apple Silicon + Intel app, an ad-hoc signature, a ZIP, and `SHA256SUMS`. To inspect and validate a release without installing or changing sleep settings:

```bash
bash install.sh --check-only --archive-dir "$PWD/dist"
```

Source: [menu bar app](Sources/main.swift), [installer](install.sh), [terminal commands](scripts/agents), [uninstaller](scripts/uninstall.sh).

MIT licensed. No analytics or network access in the app; only the installer downloads from GitHub.
