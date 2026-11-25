import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { downloadVerifiedAsset, inspectHost, installerInvocation, packageRoot, parseArgs, selectTarget, setup } from '../lib/install.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const mac = { platform: 'darwin', arch: 'arm64', version: '14.0.1' };
const windows = { platform: 'win32', arch: 'arm64', version: 26100, productType: 1, caption: 'Microsoft Windows 11 Enterprise' };

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'agents on $ & fixture-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const root = path.join(directory, 'package with spaces');
  const tempRoot = path.join(directory, 'downloads with spaces');
  await mkdir(path.join(root, 'bundled'), { recursive: true });
  await mkdir(tempRoot);
  const installer = Buffer.from('# fixture installer: never actually executed\n');
  const payload = Buffer.from('a pinned, verified fixture payload');
  const manifest = {
    schemaVersion: 1,
    platforms: {
      darwin: { release: 'v0.5.0', installer: { file: 'install-macos.sh', sha256: hash(installer) }, assets: { universal: { file: 'Agents-On-macOS.zip', sha256: hash(payload), bytes: payload.length } } },
      win32: { release: 'v0.7.0', installer: { file: 'install-windows.ps1', sha256: hash(installer) }, assets: Object.fromEntries(['x64', 'arm64'].map(arch => [arch, { file: `Agents-On-Windows-win-${arch}.zip`, sha256: hash(payload), bytes: payload.length }])) },
    },
  };
  await writeFile(path.join(root, 'versions.json'), JSON.stringify(manifest));
  await writeFile(path.join(root, 'bundled', 'install-macos.sh'), installer);
  await writeFile(path.join(root, 'bundled', 'install-windows.ps1'), installer);
  const urls = [];
  const fetchImpl = async url => { urls.push(url); return new Response(payload); };
  return { root, tempRoot, installer, payload, manifest, urls, fetchImpl };
}

test('CLI defaults and explicit commands do not turn npm package installation into setup', async () => {
  assert.deepEqual(parseArgs([]), { command: 'install' });
  assert.deepEqual(parseArgs(['install']), { command: 'install' });
  assert.deepEqual(parseArgs(['--check']), { command: 'check' });
  assert.deepEqual(parseArgs(['install', '--check']), { command: 'check' });
  assert.deepEqual(parseArgs(['--help']), { command: 'help' });
  assert.deepEqual(parseArgs(['--version']), { command: 'version' });
  assert.throws(() => parseArgs(['--unexpected']), /--help/);
  const metadata = JSON.parse(await readFile(path.join(packageRoot, 'package.json'), 'utf8'));
  assert.equal(metadata.version, '0.7.1');
  assert.equal(metadata.dependencies, undefined);
  assert.deepEqual(Object.keys(metadata.scripts), ['test']);
});

test('tagged installer bytes match the pinned manifest', async () => {
  const manifest = JSON.parse(await readFile(path.join(packageRoot, 'versions.json'), 'utf8'));
  for (const release of Object.values(manifest.platforms)) {
    const bytes = await readFile(path.join(packageRoot, 'bundled', release.installer.file));
    assert.equal(hash(bytes), release.installer.sha256);
  }
});

test('target validation rejects Linux, Windows Server/10, unsupported architecture, and old macOS', async t => {
  const f = await fixture(t);
  assert.throws(() => selectTarget({ platform: 'linux', arch: 'x64' }, f.manifest), /Linux/);
  assert.throws(() => selectTarget({ ...mac, version: '13.6.9' }, f.manifest), /macOS 14/);
  assert.throws(() => selectTarget({ ...mac, version: 'unknown' }, f.manifest), /macOS 14/);
  assert.throws(() => selectTarget({ ...windows, productType: 3, caption: 'Microsoft Windows Server 2025' }, f.manifest), /Windows Server/);
  assert.throws(() => selectTarget({ ...windows, version: 19045, caption: 'Microsoft Windows 10' }, f.manifest), /Windows 11/);
  assert.throws(() => selectTarget({ ...windows, arch: 'ia32' }, f.manifest), /64-bit/);
  assert.equal(selectTarget({ ...mac, version: '27.0.1', arch: 'x64' }, f.manifest).asset.file, 'Agents-On-macOS.zip');
});

test('Windows host inspection chooses native ARM64 when Node runs under x64 emulation', () => {
  const calls = [];
  const host = inspectHost({ platform: 'win32', arch: 'x64', env: { SystemRoot: 'C:\\Windows root' }, execute: (...args) => { calls.push(args); return { status: 0, stdout: JSON.stringify({ productType: 1, build: 26100, caption: 'Microsoft Windows 11 Enterprise', architecture: 'Arm64' }) }; } });
  assert.equal(host.arch, 'arm64');
  assert.equal(calls[0][0], 'C:\\Windows root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
  assert.equal(calls[0][2].shell, false);
  assert.throws(() => inspectHost({ platform: 'win32', execute: () => ({ status: 1 }) }), /Could not verify/);
  assert.throws(() => inspectHost({ platform: 'linux' }), /Linux/);
});

test('macOS uses the actual product version rather than the Darwin kernel version', () => {
  const calls = [];
  const host = inspectHost({ platform: 'darwin', arch: 'arm64', execute: (...args) => { calls.push(args); return { status: 0, stdout: '14.6.1\n' }; } });
  assert.equal(host.version, '14.6.1');
  assert.deepEqual(calls[0].slice(0, 2), ['/usr/bin/sw_vers', ['-productVersion']]);
});

test('Mac installer receives verified private files and intact argument paths with spaces', async t => {
  const f = await fixture(t);
  let calls = 0;
  await setup({ root: f.root, tempRoot: f.tempRoot }, {
    host: mac, fetchImpl: f.fetchImpl, log: () => {},
    run: async invocation => {
      calls++;
      assert.equal(invocation.command, '/bin/bash');
      assert.equal(invocation.options.shell, false);
      assert.equal(invocation.options.stdio, 'inherit');
      assert.equal(invocation.args.length, 3);
      assert.equal(invocation.args[1], '--archive-dir');
      const script = invocation.args[0], archiveDirectory = invocation.args[2];
      assert.ok(script.includes('downloads with spaces'));
      assert.notEqual(script, path.join(f.root, 'bundled', 'install-macos.sh'));
      assert.deepEqual(await readFile(script), f.installer);
      assert.deepEqual(await readFile(path.join(archiveDirectory, 'Agents-On-macOS.zip')), f.payload);
      assert.equal(await readFile(path.join(archiveDirectory, 'SHA256SUMS'), 'utf8'), `${hash(f.payload)}  Agents-On-macOS.zip\n`);
    },
  });
  assert.equal(calls, 1);
  assert.deepEqual(await readdir(f.tempRoot), []);
  assert.deepEqual(f.urls, ['https://github.com/brandon-cor/agents-on/releases/download/v0.5.0/Agents-On-macOS.zip']);
});

test('Windows invokes a script file with literal path arguments and respects execution policy', async t => {
  const f = await fixture(t);
  let calls = 0;
  await setup({ root: f.root, tempRoot: f.tempRoot }, {
    host: windows, fetchImpl: f.fetchImpl, log: () => {},
    env: { SystemRoot: 'C:\\Windows root', agents_on_installer: 'untrusted', AGENTS_ON_ARCHIVE: 'untrusted', AgEnTs_On_ArChIvE: 'also untrusted' },
    run: async invocation => {
      calls++;
      assert.equal(invocation.command, 'C:\\Windows root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
      assert.equal(invocation.options.shell, false);
      assert.ok(!invocation.args.some(arg => /ExecutionPolicy|Bypass|Unblock/i.test(arg)));
      assert.equal(invocation.args.length, 7);
      assert.deepEqual(invocation.args.slice(0, 4), ['-NoLogo', '-NoProfile', '-NonInteractive', '-File']);
      assert.equal(invocation.args[5], '-ArchivePath');
      assert.deepEqual(await readFile(invocation.args[4]), f.installer);
      assert.deepEqual(await readFile(invocation.args[6]), f.payload);
      assert.equal(await readFile(`${invocation.args[6]}.sha256`, 'utf8'), `${hash(f.payload)}  Agents-On-Windows-win-arm64.zip\n`);
    },
  });
  assert.equal(calls, 1);
  assert.deepEqual(await readdir(f.tempRoot), []);
  const invocation = installerInvocation(windows, { directory: 'C:\\A & B', installerPath: 'C:\\A & B\\script.ps1', archivePath: 'C:\\A & B\\payload.zip', env: {} });
  assert.deepEqual(invocation.args.slice(3), ['-File', 'C:\\A & B\\script.ps1', '-ArchivePath', 'C:\\A & B\\payload.zip']);
});

test('checksum failure removes the download and prevents all installer execution', async t => {
  const f = await fixture(t);
  let runs = 0;
  await assert.rejects(setup({ root: f.root, tempRoot: f.tempRoot }, { host: mac, fetchImpl: async () => new Response(Buffer.alloc(f.payload.length)), run: () => { runs++; }, log: () => {} }), /SHA-256/);
  assert.equal(runs, 0);
  assert.deepEqual(await readdir(f.tempRoot), []);
});

test('tampered bundled script fails before any network request or execution', async t => {
  const f = await fixture(t);
  await writeFile(path.join(f.root, 'bundled', 'install-macos.sh'), 'unverified script');
  let downloads = 0, runs = 0;
  await assert.rejects(setup({ root: f.root, tempRoot: f.tempRoot }, { host: mac, fetchImpl: () => { downloads++; }, run: () => { runs++; }, log: () => {} }), /bundled installer failed/);
  assert.equal(downloads, 0);
  assert.equal(runs, 0);
  assert.deepEqual(await readdir(f.tempRoot), []);
});

test('--check verifies the actual bytes while never invoking installation', async t => {
  const f = await fixture(t);
  let runs = 0;
  const result = await setup({ checkOnly: true, root: f.root, tempRoot: f.tempRoot }, { host: windows, fetchImpl: f.fetchImpl, run: () => { runs++; }, log: () => {} });
  assert.equal(result.checked, true);
  assert.equal(result.release, 'v0.7.0');
  assert.equal(runs, 0);
  assert.deepEqual(await readdir(f.tempRoot), []);
});

test('oversized or truncated payloads cannot pass pinned verification', async t => {
  const f = await fixture(t);
  for (const payload of [Buffer.alloc(f.payload.length + 1), f.payload.subarray(1)]) {
    const destination = path.join(f.tempRoot, 'payload.zip');
    await assert.rejects(downloadVerifiedAsset('https://example.invalid/payload', destination, f.manifest.platforms.darwin.assets.universal, { fetchImpl: async () => new Response(payload) }));
    await assert.rejects(access(destination));
  }
});

test('installer failure still cleans temporary verified files', async t => {
  const f = await fixture(t);
  await assert.rejects(setup({ root: f.root, tempRoot: f.tempRoot }, { host: mac, fetchImpl: f.fetchImpl, run: () => { throw new Error('fixture installer failed'); }, log: () => {} }), /fixture installer failed/);
  assert.deepEqual(await readdir(f.tempRoot), []);
});

test('help and version work without triggering setup', () => {
  const executable = fileURLToPath(new URL('../bin/agents-on.mjs', import.meta.url));
  assert.equal(execFileSync(process.execPath, [executable, '--version'], { encoding: 'utf8' }).trim(), '0.7.1');
  assert.match(execFileSync(process.execPath, [executable, '--help'], { encoding: 'utf8' }), /Installing the npm package itself never runs app setup/);
});
