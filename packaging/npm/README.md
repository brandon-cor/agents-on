# agents-on

Install the **Agents On** macOS menu bar app or Windows tray app:

```sh
npx --yes https://github.com/brandon-cor/agents-on/releases/download/v0.7.1/agents-on-0.7.1.tgz
```

Or install the command first, then run setup:

```sh
npm install -g https://github.com/brandon-cor/agents-on/releases/download/v0.7.1/agents-on-0.7.1.tgz
agents-on install
```

Installing this npm package alone does not run app setup. There are no installation hooks or dependencies.

This public GitHub package URL works without an npm account. It installs the exact version in the URL.

Requires Node.js 20 or later, plus macOS 14+ or Windows 11 on x64/ARM64. The command selects your platform, downloads a pinned release, verifies its SHA-256 checksum and the bundled installer, then starts the existing platform installer. macOS asks for your password for its one-time sleep permissions. Windows installs per user. Normal Windows security and macOS Gatekeeper settings still apply.

To verify the download without installing or changing sleep settings:

```sh
agents-on --check
```

This npm wrapper is version **0.7.1**. Its pinned app releases are **macOS v0.5.0** and **Windows v0.7.0**. It does not change the app's features or background behavior.

[App features and manual downloads](https://github.com/brandon-cor/agents-on)
