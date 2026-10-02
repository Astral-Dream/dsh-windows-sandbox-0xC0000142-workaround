// One-shot installer for the DSH Windows sandbox fix (v2).
//
// Why: the ACL restricted-token sandbox spawns its child with a restricted
// token. When the sandbox runner is hosted by Electron-as-Node, that child dies
// during DLL initialization (STATUS_DLL_INIT_FAILED / 0xC0000142). Hosting the
// runner with the bundled plain Node runtime works, but plain Node cannot read
// paths inside app.asar -- so a real-filesystem copy of the whole sandbox
// support tree is materialized once, and the in-archive runner is patched to
// re-exec itself from that copy.
//
// The pristine runner is taken from the app.asar.backup-gitfix if present,
// which avoids ever copying an already-patched version into the real tree.
//
// Usage: node dsh-install-fix2.mjs "<app.asar>" "<realFsDir>" "<plain node.exe>" ["<logPath>"] ["<pristineRunner.js>"]
import { readFileSync, writeFileSync, copyFileSync, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';

const ARCHIVE_PATH = 'dsh/node_modules/@deepseek-ai/dsh-sandbox-windows-acl/lib/runner.js';
const RUNNER_REAL = 'dsh/node_modules/@deepseek-ai/dsh-sandbox-windows-acl/lib/runner.js';

const ASAR = process.argv[2];
const REALDIR = process.argv[3];
const PLAIN = process.argv[4];
const LOGPATH = process.argv[5] || '';
const EXPLICIT_PRISTINE = process.argv[6] || '';
if (!ASAR || !REALDIR || !PLAIN) {
  console.error('usage: node dsh-install-fix2.mjs <app.asar> <realFsDir> <plainNodeExe> [logPath] [pristineRunner.js]');
  process.exit(2);
}
if (!existsSync(ASAR)) { console.error(`ERROR: app.asar not found: ${ASAR}`); process.exit(1); }
if (!existsSync(PLAIN)) { console.error(`ERROR: plain node not found: ${PLAIN}`); process.exit(1); }

// ------------------------------------------------------------------ asar reader
function readAsar(file) {
  const b = readFileSync(file);
  const a = b.indexOf(Buffer.from('{"files":{'));
  if (a < 0) throw new Error(`asar header not found in ${file}`);
  let dd = 0, e = -1, s = false, esc = false;
  for (let i = a; i < b.length; i++) {
    const c = b[i];
    if (s) { if (esc) esc = false; else if (c === 0x5c) esc = true; else if (c === 0x22) s = false; continue; }
    if (c === 0x22) s = true;
    else if (c === 0x7b) dd++;
    else if (c === 0x7d) { dd--; if (dd === 0) { e = i + 1; break; } }
  }
  if (e < 0) throw new Error('unterminated asar header');
  return { buf: b, header: JSON.parse(b.subarray(a, e).toString('utf8')), dataStart: e };
}
function walk(node, prefix, out) {
  for (const [name, entry] of Object.entries(node.files || {})) {
    const p = prefix ? `${prefix}/${name}` : name;
    if (entry.files) walk(entry, p, out);
    else out.push({ path: p, offset: Number(entry.offset), size: entry.size, unpacked: !!entry.unpacked });
  }
  return out;
}
const findEntry = (h, p) => {
  let n = h;
  for (const seg of p.split('/')) n = n && n.files ? n.files[seg] : undefined;
  return n;
};
/** Recursively copy a real directory tree. */
function copyTree(src, dst) {
  mkdirSync(dst, { recursive: true });
  for (const e of readdirSync(src, { withFileTypes: true })) {
    const s = join(src, e.name);
    const d = join(dst, e.name);
    if (e.isDirectory()) copyTree(s, d);
    else if (e.isFile()) copyFileSync(s, d);
  }
}

const { buf, header, dataStart } = readAsar(ASAR);
const all = walk(header, '', []);

// ------------------------------------------------------- pick the pristine source
const BACKUP = `${ASAR}.backup-gitfix`;
const backupExists = existsSync(BACKUP);
const backupAsar = backupExists ? readAsar(BACKUP) : null;

// Pick the PRISTINE runner bytes, in order of trustworthiness.
// 1) an explicit file supplied by the caller (survives app updates),
// 2) the pre-update backup,
// 3) app.asar itself (only correct if it has never been patched).
let pristineRunner = null;
let pristineSource = '';
if (EXPLICIT_PRISTINE && existsSync(EXPLICIT_PRISTINE)) {
  pristineRunner = readFileSync(EXPLICIT_PRISTINE);
  pristineSource = `${EXPLICIT_PRISTINE} (explicit)`;
} else {
  const n = backupAsar ? findEntry(backupAsar.header, ARCHIVE_PATH) : undefined;
  if (n && !n.files && !n.unpacked) {
    pristineRunner = backupAsar.buf.subarray(backupAsar.dataStart + Number(n.offset), backupAsar.dataStart + Number(n.offset) + n.size);
    pristineSource = `${BACKUP} (backup)`;
  } else {
    const l = findEntry(header, ARCHIVE_PATH);
    if (l && !l.files && !l.unpacked) {
      pristineRunner = Buffer.from(buf.subarray(dataStart + Number(l.offset), dataStart + Number(l.offset) + l.size));
      pristineSource = 'app.asar (WARNING: may already be patched)';
    }
  }
}
if (!pristineRunner) { console.error('ERROR: could not locate a pristine runner to start from'); process.exit(1); }
console.log(`pristine runner source: ${pristineSource}`);
console.log(`pristine runner size  : ${pristineRunner.length} bytes`);

// ------------------------------------------- step 1: materialize the real tree
// 1a. copy the physical node_modules tree (third-party deps that live unpacked)
const PHYSICAL = join(`${ASAR}.unpacked`, 'dsh', 'node_modules');
if (existsSync(PHYSICAL)) {
  console.log('copying third-party dependencies from app.asar.unpacked ...');
  copyTree(PHYSICAL, join(REALDIR, 'dsh', 'node_modules'));
} else {
  console.log(`WARNING: ${PHYSICAL} not found; third-party deps may be missing`);
}

// 1b. overlay the ESM packages that live packed inside app.asar
const PREFIXES = [
  'dsh/node_modules/@deepseek-ai/',
  'dsh/node_modules/yaml/',
  'dsh/node_modules/koffi/',
  'dsh/node_modules/@koromix/',
];
const toExtract = all.filter(f => PREFIXES.some(p => f.path.startsWith(p)));
console.log(`overlaying ${toExtract.length} packed files into ${REALDIR} ...`);

let written = 0, fromBackup = 0, skippedReal = 0;
for (const f of toExtract) {
  const dest = join(REALDIR, ...f.path.split('/'));
  mkdirSync(dirname(dest), { recursive: true });
  if (f.path === ARCHIVE_PATH) {
    // Write the PRISTINE bytes into the real tree. Copying a patched runner
    // here would make it re-exec itself forever.
    writeFileSync(dest, pristineRunner);
    fromBackup++; written++; continue;
  }
  if (f.unpacked && existsSync(dest)) {
    // The archive stores a placeholder for unpacked files; the real bytes were
    // copied from app.asar.unpacked in step 1a. Never overwrite them.
    skippedReal++; continue;
  }
  writeFileSync(dest, buf.subarray(dataStart + f.offset, dataStart + f.offset + f.size));
  written++;
}
console.log(`overlaid ${written} files (${fromBackup} runner from backup, ${skippedReal} real binaries preserved)`);

const CLEAN = join(REALDIR, ...RUNNER_REAL.split('/'));
const MUST = [
  CLEAN,
  join(REALDIR, 'dsh', 'node_modules', '@deepseek-ai', 'dsh-sandbox-windows-acl', 'lib', 'types-Cl_DXjhk.js'),
  join(REALDIR, 'dsh', 'node_modules', '@deepseek-ai', 'dsh-win32-process', 'lib', 'index.js'),
  join(REALDIR, 'dsh', 'node_modules', '@deepseek-ai', 'dsh-subprocess', 'lib', 'control.js'),
  join(REALDIR, 'dsh', 'node_modules', 'koffi'),
];
for (const p of MUST) if (!existsSync(p)) { console.error(`ERROR: extraction incomplete, missing: ${p}`); process.exit(1); }

// Native addons must be real PE binaries, not asar placeholders (MZ header).
function assertNative(file) {
  if (!existsSync(file)) return;   // some builds place it elsewhere
  const h = readFileSync(file).subarray(0, 2).toString('latin1');
  if (h !== 'MZ') {
    console.error(`ERROR: ${file} is not a valid Windows binary (header=${JSON.stringify(h)}).`);
    console.error('       Refusing to install. Nothing was written to app.asar.');
    process.exit(1);
  }
  console.log(`native binary OK: ${file}`);
}
assertNative(join(REALDIR, 'dsh', 'node_modules', '@koromix', 'koffi-win32-x64', 'win32_x64', 'koffi.node'));
assertNative(join(REALDIR, 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'node_modules', '@koromix', 'koffi-win32-x64', 'win32_x64', 'koffi.node'));
console.log('extraction verified');

// ------------------------------------------------- step 2: build the fixed runner
const raw = readFileSync(CLEAN, 'utf8');
const originalSize = Buffer.byteLength(raw, 'utf8');

function stripComments(code) {
  let out = '', i = 0; const n = code.length; let mode = 'code';
  while (i < n) {
    const c = code[i], next = code[i + 1];
    if (mode === 'code') {
      if (c === '/' && next === '/') { mode = 'line'; i += 2; continue; }
      if (c === '/' && next === '*') { mode = 'block'; i += 2; continue; }
      if (c === '"' || c === "'" || c === '`') { mode = c; out += c; i++; continue; }
      out += c; i++; continue;
    }
    if (mode === 'line') { if (c === '\n') { mode = 'code'; out += c; } i++; continue; }
    if (mode === 'block') { if (c === '*' && next === '/') { mode = 'code'; i += 2; } else i++; continue; }
    out += c;
    if (c === '\\') { out += code[i + 1] ?? ''; i += 2; continue; }
    if (c === mode) mode = 'code';
    i++;
  }
  return out;
}

let src = stripComments(raw);
console.log(`comments stripped: reclaimed ${originalSize - Buffer.byteLength(src, 'utf8')} bytes`);

const wantsLog = LOGPATH.trim().length > 0;
if (wantsLog && !/import\s*\{[^}]*appendFileSync[^}]*\}\s*from\s*"node:fs"/.test(src)) {
  src = src.replace(
    'import { closeSync, existsSync, mkdtempSync, rmSync, statSync } from "node:fs";',
    'import { appendFileSync, closeSync, existsSync, mkdtempSync, rmSync, statSync } from "node:fs";'
  );
  if (!src.includes('appendFileSync, closeSync')) { console.error('ERROR: fs import patch failed'); process.exit(1); }
}
const diag = wantsLog
  ? `function dg(e,x){try{appendFileSync(${JSON.stringify(LOGPATH)},JSON.stringify(Object.assign({ev:e},x))+"\\n")}catch(_){}}\n`
  : `function dg(){}\n`;

const REEXEC = `
if (process.versions.electron !== void 0) {
	const real = ${JSON.stringify(CLEAN)};
	const pn = ${JSON.stringify(PLAIN)};
	if (existsSync(real) && existsSync(pn)) {
		dg("reexec",{from:process.execPath,to:pn,real:real});
		const r = (await import("node:child_process")).spawnSync(pn, [real, ...process.argv.slice(2)], { stdio: "inherit" });
		process.exit(r.status === null ? 1 : r.status);
	}
	dg("reexec-skipped",{real:real,pn:pn});
}
`;

const steps = [
  ['RUNNER_FAILURE_EXIT', (s) => s.replace('const RUNNER_FAILURE_EXIT = 127;', `const RUNNER_FAILURE_EXIT = 127;\n${diag}`)],
  ['main()', (s) => s.replace('async function main() {', `async function main() {\n\tdg("start",{a:process.argv.slice(2),e:process.execPath});${REEXEC}`)],
  ['sandbox.spawn', (s) => s.replace('\t\tconst child = sandbox.spawn({', `\t\tdg("pre",{s:seamManaged,m:parsed.mode,c:parsed.command});\n\t\tconst child = sandbox.spawn({`)],
  ['child.wait', (s) => s.replace('\t\treturn (await child.wait()).exitCode;', `\t\tconst x=(await child.wait()).exitCode;\n\t\tdg("exit",{code:x});\n\t\treturn x;`)],
  ['RunnerFailure', (s) => s.replace('\tif (!(error instanceof RunnerFailure))', `\tdg("rej",{m:error instanceof Error?error.message:String(error)});\n\tif (!(error instanceof RunnerFailure))`)],
];
for (const [label, fn] of steps) {
  const before = src; src = fn(src);
  if (src === before) { console.error(`ERROR: anchor not found: ${label}`); process.exit(1); }
}

const patchedBytes = Buffer.byteLength(src, 'utf8');
if (patchedBytes > originalSize) {
  console.error(`ERROR: patched runner is ${patchedBytes} bytes > slot ${originalSize}. Aborting (nothing written).`);
  process.exit(1);
}
const padded = Buffer.from(src + ' '.repeat(originalSize - patchedBytes), 'utf8');
console.log(`fixed runner: ${patchedBytes} bytes code + ${originalSize - patchedBytes} padding = ${padded.length}`);

// ------------------------------------------------- step 3: write into app.asar
const entry = findEntry(header, ARCHIVE_PATH);
if (!entry || entry.files) { console.error(`ERROR: archive entry not found: ${ARCHIVE_PATH}`); process.exit(1); }
if (entry.unpacked) { console.error('ERROR: entry is unpacked; only packed entries are supported'); process.exit(1); }
if (entry.size !== originalSize) {
  console.error(`ERROR: archive slot is ${entry.size} bytes but the extracted runner is ${originalSize}. Aborting.`);
  process.exit(1);
}
const abs = dataStart + Number(entry.offset);
const actual = createHash('sha256').update(buf.subarray(abs, abs + entry.size)).digest('hex');
const pristineHash = createHash('sha256').update(raw, 'utf8').digest('hex');
console.log(`slot matches pristine runner: ${actual === pristineHash}`);

// app.asar.backup-gitfix is the PRISTINE pre-fix archive: it is the fallback
// source for the runner, so never overwrite it. After an app update a fresh
// rollback copy is kept under a timestamped name instead.
if (!backupExists) { copyFileSync(ASAR, BACKUP); console.log(`pristine backup written: ${BACKUP}`); }
else {
  console.log(`pristine backup kept: ${BACKUP}`);
  const current = createHash('sha256').update(readFileSync(ASAR)).digest('hex');
  const known = createHash('sha256').update(readFileSync(BACKUP)).digest('hex');
  if (current !== known) {
    const ts = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    const rollback = `${ASAR}.pre-fix-${ts}`;
    if (!existsSync(rollback)) { copyFileSync(ASAR, rollback); console.log(`rollback copy written: ${rollback}`); }
  }
}

padded.copy(buf, abs);
writeFileSync(ASAR, buf);
console.log(`OK: fix installed in place (archive size unchanged: ${buf.length} bytes)`);
console.log(`real-filesystem support tree: ${REALDIR}`);
console.log(`plain node runtime: ${PLAIN}`);
console.log(wantsLog ? `diagnostic log: ${LOGPATH}` : 'diagnostic logging: off');
