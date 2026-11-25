import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtemp, open, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const packageRoot = fileURLToPath(new URL('../', import.meta.url));
const powershellHostQuery = '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$o=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop; @{productType=[int]$o.ProductType;build=[int]$o.BuildNumber;caption=$o.Caption;architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()} | ConvertTo-Json -Compress';

export function parseArgs(args) {
  if (args.length === 0 || (args.length === 1 && args[0] === 'install')) return { command: 'install' };
  if (args.length === 1 && ['--help', '-h', 'help'].includes(args[0])) return { command: 'help' };
  if (args.length === 1 && ['--version', '-v'].includes(args[0])) return { command: 'version' };
  if ((args.length === 1 && args[0] === '--check') || (args.length === 2 && args[0] === 'install' && args[1] === '--check')) return { command: 'check' };
  throw new Error('Use agents-on install, agents-on --check, or agents-on --help.');
}

export function windowsPowerShell(env = process.env) {
  return path.win32.join(env.SystemRoot || env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

function windowsPowerShellEnvironment(env) {
  // PowerShell 7 module paths break Windows PowerShell when inherited through Node.
  // Let the child rebuild its defaults; keep execution-policy variables intact.
  return Object.fromEntries(Object.entries(env).filter(([key]) => key.toUpperCase() !== 'PSMODULEPATH'));
}

export function inspectHost({ platform = process.platform, arch = process.arch, env = process.env, execute = spawnSync } = {}) {
  if (platform === 'darwin') {
    const result = execute('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8', windowsHide: true, shell: false });
    if (result.error || result.status !== 0) throw new Error('Could not read the macOS version.');
    return { platform, arch, version: result.stdout.trim() };
  }
  if (platform === 'win32') {
    const powershell = windowsPowerShell(env);
    const result = execute(powershell, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', powershellHostQuery], { encoding: 'utf8', windowsHide: true, shell: false, timeout: 90_000, env: windowsPowerShellEnvironment(env) });
    if (result.error || result.status !== 0) {
      const reason = result.error?.code || result.stderr?.trim().slice(0, 1000) || `exit ${result.status}`;
      throw new Error(`Could not verify Windows 11 (${reason}). Open PowerShell and check that Windows system information is available.`);
    }
    let info;
    try { info = JSON.parse(result.stdout.trim()); } catch { throw new Error('Windows returned unreadable system information.'); }
    const nativeArch = { arm64: 'arm64', x64: 'x64', amd64: 'x64' }[String(info.architecture).toLowerCase()];
    return { platform, arch: nativeArch, version: info.build, productType: info.productType, caption: info.caption, powershell };
  }
  throw new Error('Agents On supports macOS 14 or later and Windows 11. Linux is not supported.');
}

export function selectTarget(host, manifest) {
  if (!['darwin', 'win32'].includes(host.platform)) throw new Error('Agents On supports macOS and Windows; Linux is not supported.');
  if (!['arm64', 'x64'].includes(host.arch)) throw new Error('Agents On requires an Apple Silicon/Intel Mac or a 64-bit x64/ARM64 Windows PC.');
  if (host.platform === 'darwin') {
    if (!/^\d+\.\d+(?:\.\d+)?$/.test(String(host.version)) || Number(String(host.version).split('.')[0]) < 14) throw new Error('Agents On requires macOS 14 or later.');
  } else if (host.productType !== 1 || !Number.isInteger(Number(host.version)) || Number(host.version) < 22000 || !/Windows 11/i.test(host.caption || '')) {
    throw new Error('Agents On requires Windows 11; Windows 10 and Windows Server are not supported by this installer.');
  }
  const release = manifest.platforms?.[host.platform];
  const asset = release?.assets?.[host.platform === 'darwin' ? 'universal' : host.arch];
  if (!release || !asset || !/^v\d+\.\d+\.\d+$/.test(release.release)) throw new Error('The bundled release manifest is invalid.');
  for (const item of [asset, release.installer]) {
    if (!item || !/^[A-Za-z0-9_.-]+$/.test(item.file) || !/^[a-f0-9]{64}$/.test(item.sha256)) throw new Error('The bundled release manifest is invalid.');
  }
  if (!Number.isSafeInteger(asset.bytes) || asset.bytes <= 0) throw new Error('The bundled download size is invalid.');
  return { ...host, release: release.release, installer: release.installer, asset };
}

export async function downloadVerifiedAsset(url, destination, asset, { fetchImpl = globalThis.fetch } = {}) {
  let handle;
  try {
    const response = await fetchImpl(url, { redirect: 'follow', signal: AbortSignal.timeout(180_000) });
    if (!response.ok || !response.body || (response.url && new URL(response.url).protocol !== 'https:')) throw new Error('The release download did not complete.');
    handle = await open(destination, 'wx', 0o600);
    const digest = createHash('sha256');
    let total = 0;
    for await (const value of response.body) {
      const chunk = Buffer.from(value);
      total += chunk.length;
      if (total > asset.bytes) throw new Error('The release download exceeded its pinned size.');
      digest.update(chunk);
      for (let offset = 0; offset < chunk.length;) {
        const written = await handle.write(chunk, offset, chunk.length - offset);
        if (written.bytesWritten === 0) throw new Error('Could not save the release download.');
        offset += written.bytesWritten;
      }
    }
    if (total !== asset.bytes || digest.digest('hex') !== asset.sha256) throw new Error('The downloaded app failed SHA-256 verification. Nothing was installed.');
    await handle.close();
    handle = null;
  } catch (error) {
    if (handle) await handle.close().catch(() => {});
    await rm(destination, { force: true }).catch(() => {});
    if (error.message?.includes('SHA-256') || error.message?.includes('pinned size')) throw error;
    throw new Error('Could not download and verify Agents On. Check your connection and retry; nothing was installed.');
  }
}

export function installerInvocation(target, { directory, installerPath, archivePath, env = process.env }) {
  if (target.platform === 'darwin') {
    return { command: '/bin/bash', args: [installerPath, '--archive-dir', directory], options: { stdio: 'inherit', shell: false, env } };
  }
  return {
    command: target.powershell || windowsPowerShell(env),
    args: ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', installerPath, '-ArchivePath', archivePath],
    options: { stdio: 'inherit', shell: false, env: windowsPowerShellEnvironment(env) },
  };
}

export function runInstaller(invocation) {
  const result = spawnSync(invocation.command, invocation.args, invocation.options);
  if (result.error) throw new Error(`Could not start the platform installer (${result.error.code || 'unknown error'}).`);
  if (result.signal) throw new Error('Installation was interrupted.');
  if (result.status !== 0) throw new Error('The platform installer did not finish. Review its message above before retrying.');
}

export async function setup({ checkOnly = false, root = packageRoot, tempRoot = os.tmpdir() } = {}, {
  host = inspectHost,
  fetchImpl = globalThis.fetch,
  run = runInstaller,
  env = process.env,
  log = console.log,
} = {}) {
  const manifest = JSON.parse(await readFile(path.join(root, 'versions.json'), 'utf8'));
  if (manifest.schemaVersion !== 1) throw new Error('The bundled release manifest version is invalid.');
  const target = selectTarget(typeof host === 'function' ? host() : host, manifest);
  const installer = await readFile(path.join(root, 'bundled', target.installer.file));
  if (createHash('sha256').update(installer).digest('hex') !== target.installer.sha256) throw new Error('The bundled installer failed SHA-256 verification. Nothing was installed.');
  const directory = await mkdtemp(path.join(tempRoot, 'agents-on-'));
  try {
    const installerPath = path.join(directory, target.installer.file);
    await writeFile(installerPath, installer, { mode: 0o600, flag: 'wx' });
    const archivePath = path.join(directory, target.asset.file);
    log(`Downloading Agents On ${target.release} for ${target.platform === 'darwin' ? 'macOS' : 'Windows'}…`);
    const url = `https://github.com/brandon-cor/agents-on/releases/download/${target.release}/${target.asset.file}`;
    await downloadVerifiedAsset(url, archivePath, target.asset, { fetchImpl });
    const sidecar = target.platform === 'darwin' ? path.join(directory, 'SHA256SUMS') : `${archivePath}.sha256`;
    await writeFile(sidecar, `${target.asset.sha256}  ${target.asset.file}\n`, { mode: 0o600 });
    if (checkOnly) {
      log('App download and bundled installer verified. Nothing was installed or changed.');
      return { checked: true, platform: target.platform, release: target.release, asset: target.asset.file };
    }
    log('Starting the verified installer…');
    await run(installerInvocation(target, { directory, installerPath, archivePath, env }));
    return { checked: false, platform: target.platform, release: target.release, asset: target.asset.file };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
