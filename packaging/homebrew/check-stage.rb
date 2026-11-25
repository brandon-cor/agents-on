# typed: strict
# frozen_string_literal: true

# Run with: brew ruby packaging/homebrew/check-stage.rb
# Installs only into a disposable prefix; never performs the account setup.
require "formula"
require "open3"
require "tmpdir"

formula_path = Pathname.new(__dir__)/"Formula/agents-on.rb"
formula = Formulary.factory(formula_path)

Dir.mktmpdir("agents-on-homebrew-") do |directory|
  root = Pathname.new(directory)
  staged_prefix = root/"prefix"
  # Exercise Homebrew's real fetch, checksum, archive staging, and install DSL.
  formula.define_singleton_method(:prefix) { |*_args| staged_prefix }
  formula.brew { formula.install }

  command = (staged_prefix/"bin/agents-on").to_s
  fake_home = root/"home"
  fake_home.mkpath
  run = lambda do |argument, expected_status = 0|
    stdout, stderr, status = Open3.capture3({ "HOME" => fake_home.to_s }, command, argument)
    if status.exitstatus != expected_status
      raise "#{argument} exited #{status.exitstatus}, expected #{expected_status}: #{stdout}#{stderr}"
    end

    stdout + stderr
  end
  raise "Help is missing" unless run.call("--help").include?("Agents On for macOS")
  raise "Version is wrong" if run.call("--version").strip != "0.5.0"
  unless run.call("verify").include?("No installation or sleep settings changed")
    raise "Read-only release verification failed"
  end
  unless run.call("status", 1).include?("Finish setup first")
    raise "Missing account setup was not reported"
  end

  run.call("invalid-command", 2)

  # Check command forwarding using a fake per-user CLI, not the installed app.
  cli = fake_home/".local/bin/agents"
  cli.dirname.mkpath
  cli.write("#!/bin/bash\nprintf 'forwarded:%s\\n' \"$1\"\n")
  cli.chmod(0755)
  %w[on off status show doctor].each do |argument|
    raise "Incorrect #{argument} forwarding" if run.call(argument).strip != "forwarded:#{argument}"
  end

  # After verifying the real pinned installer, replace this temporary copy with
  # an argument-recording stub. Never run the interactive setup in a test.
  installer = staged_prefix/"libexec/install.sh"
  installer.unlink
  installer.write("#!/bin/bash\nprintf '%s\\n' \"$@\"\n")
  expected_archive_arguments = "--archive-dir\n#{staged_prefix}/libexec\n"
  raise "Setup arguments are wrong" if run.call("install") != expected_archive_arguments
  if run.call("verify") != "--check-only\n#{expected_archive_arguments}"
    raise "Verification arguments are wrong"
  end

  uninstaller = fake_home/"Library/Application Support/Agents On/uninstall.sh"
  uninstaller.dirname.mkpath
  uninstaller.write("#!/bin/bash\nprintf 'uninstall stub\\n'\n")
  raise "Incorrect uninstall forwarding" if run.call("uninstall").strip != "uninstall stub"

  puts "Homebrew staging, real release verification, and CLI forwarding passed without account setup."
end
