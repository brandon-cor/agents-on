# Agents On Homebrew tap

This directory mirrors the formula published as `Formula/agents-on.rb` in
the public `brandon-cor/homebrew-tap` repository. It packages the verified macOS
0.5.0 release; Windows release numbers are independent.

Install and finish setup with:

```sh
brew install brandon-cor/tap/agents-on && agents-on install
```

The Homebrew step installs an `agents-on` command and the checksum-verified
release into Homebrew's prefix. It does not run the app, change sleep settings,
modify login items, or ask for administrator privileges.

`agents-on install` runs the upstream installer pinned to a clean source commit.
It uses the already downloaded release archive and asks once for a Mac password
to configure the two specific password-free sleep commands. Setup starts and
verifies the menu bar app, configures login startup and the existing `agents`
CLI, and preserves the current sleep setting. It requires macOS 14 or newer.

Useful commands:

```sh
agents-on verify    # Check the release without setting up the app.
agents-on show      # Show the menu bar indicator after setup.
agents-on status
agents-on on
agents-on off
```

After `brew upgrade`, run `agents-on install` to update the user's app copy.
To remove both the app setup and the Homebrew package:

```sh
agents-on uninstall
brew uninstall brandon-cor/tap/agents-on
```

Uninstalling only the formula removes the Homebrew command and cached package;
it leaves the separately installed app and account setup intact.

The formula is deliberately not a Cask install hook. Homebrew's Cask cookbook
requires `installer script:` to be noninteractive, while this app's one-time
permission setup needs the user's password. The explicit setup command keeps
that prompt in a normal terminal.

References: [third-party taps](https://docs.brew.sh/Taps),
[Formula cookbook](https://docs.brew.sh/Formula-Cookbook),
[Cask installer scripts](https://docs.brew.sh/Cask-Cookbook#installer-script).

Validate from the Agents On source checkout on macOS:

```sh
brew style packaging/homebrew/Formula/agents-on.rb
brew ruby packaging/homebrew/check-stage.rb
```

The staging check uses Homebrew's actual fetch and install DSL with a temporary
prefix, checks the real release without setting up the app, and tests command
forwarding against temporary stubs. It never invokes the account setup. Once the
tap is published and tapped, also run:

```sh
brew audit --strict brandon-cor/tap/agents-on
```
