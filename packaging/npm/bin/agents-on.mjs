#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { parseArgs, setup } from '../lib/install.mjs';

try {
  const { command } = parseArgs(process.argv.slice(2));
  if (command === 'help') {
    console.log(`agents-on — install the macOS menu bar or Windows 11 tray app

Usage:
  npx agents-on          Install or update the app
  agents-on install      Install after a global npm installation
  agents-on --check      Download and verify without installing
  agents-on --version    Show the npm installer version

Requires macOS 14+ or Windows 11 on x64/ARM64.
macOS asks for your password during one-time permission setup.
Installing the npm package itself never runs app setup.`);
  } else if (command === 'version') {
    const metadata = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
    console.log(metadata.version);
  } else {
    await setup({ checkOnly: command === 'check' });
  }
} catch (error) {
  console.error(`agents-on: ${error.message}`);
  process.exitCode = 1;
}
