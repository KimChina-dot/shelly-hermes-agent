#!/usr/bin/env node
// PHASE 20 (V3 plan P13, risk R5): scripted build smoke.
//
// What it does:
//   1. Resolves the build directory. R5: the AOT snapshotter breaks on
//      non-ASCII Windows paths, so the release line builds through a
//      `subst X:` drive alias. Policy:
//        - repo path already pure ASCII  -> build at the real path, no
//          subst needed (recorded in the manifest as substUsed=false).
//        - non-ASCII path + usable subst mapping (X: -> an ancestor of
//          the repo) -> build under the aliased path (substUsed=true).
//        - non-ASCII path + no usable mapping -> print the exact
//          `subst X: <dir>` fix. `--debug` continues at the real path
//          with a loud warning (debug APKs are JIT; the R5 AOT risk does
//          not apply), `--release` refuses to build (exit 1).
//   2. Runs `flutter build apk --debug` (or --release) with cwd at
//      <repo>/flutter.
//   3. On success hashes the APK (SHA-256) and writes
//      artifacts/build-smoke.json (artifact name, size, sha256,
//      timestamp, flutter --version summary, subst decision).
//
// Honest by design: a failed build exits non-zero and writes no manifest;
// nothing is faked.
//
// Usage: node scripts/build-smoke.mjs [--release]
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync } from "node:fs";
import { mkdir, readdir, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "..");
const artifactsDir = join(repoRoot, "artifacts");
const SUBST_DRIVE = "X:";
const wantRelease = process.argv.slice(2).includes("--release");
const buildMode = wantRelease ? "release" : "debug";
const apkName = `app-${buildMode}.apk`;

const nonAscii = (s) => /[^\x00-\x7F]/.test(s);

/** Quotes one shell word only when it contains shell-sensitive characters. */
function shQuote(word) {
  return /[ \t"&|^<>()%!]/.test(word) ? `"${word.replace(/"/g, '""')}"` : word;
}

/** Builds a single command line; we always run through a shell (Windows
 *  needs it for .bat/.cmd and cmd builtins like `subst`), so args are
 *  pre-joined to avoid Node's shell+args-array deprecation. */
function cmdline(cmd, args = []) {
  return [cmd, ...args.map(shQuote)].join(" ");
}

/** Runs a command line, inheriting stdio, resolving with its exit code. */
function run(cmd, args, opts = {}) {
  return new Promise((res, rej) => {
    const child = spawn(cmdline(cmd, args), { shell: true, stdio: "inherit", ...opts });
    child.on("error", rej);
    child.on("exit", (code) => res(code ?? 1));
  });
}

/** Captures stdout of a command line as a string ("" on failure). */
function capture(cmd, args, opts = {}) {
  const r = spawnSync(cmdline(cmd, args), {
    shell: true,
    encoding: "utf8",
    timeout: 120_000,
    ...opts,
  });
  return r.status === 0 ? (r.stdout || "") : "";
}

/**
 * Resolves the flutter executable. Order: PATH, FLUTTER_ROOT, then the
 * flutter.sdk recorded in flutter/android/local.properties (written by
 * `flutter pub get` on dev machines). Returns "flutter" when nothing
 * concrete is found so the shell error surfaces honestly.
 */
function resolveFlutter() {
  if (capture("where", ["flutter"], { stdio: ["ignore", "pipe", "ignore"] }).trim()) {
    return "flutter";
  }
  const candidates = [];
  if (process.env.FLUTTER_ROOT) candidates.push(process.env.FLUTTER_ROOT);
  try {
    const props = readFileSync(
      join(repoRoot, "flutter", "android", "local.properties"),
      "utf8",
    );
    const m = props.match(/^flutter\.sdk\s*=\s*(.+)$/m);
    if (m) candidates.push(m[1].trim().replace(/[/\\]+$/, ""));
  } catch {
    // no local.properties — fall through
  }
  for (const root of candidates) {
    const exe = process.platform === "win32"
      ? join(root, "bin", "flutter.bat")
      : join(root, "bin", "flutter");
    if (existsSync(exe)) return exe;
  }
  return "flutter";
}

const flutterExe = resolveFlutter();

/** Lists `subst` mappings as { drive, target } ("X:\\:" -> "I:\\some\\dir"). */
function substMappings() {
  const out = capture("subst", []);
  const maps = [];
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^([A-Z]:\\:)\s*=>\s*(.+)$/);
    if (m) maps.push({ drive: m[1].slice(0, 2), target: m[2].trim() });
  }
  return maps;
}

/**
 * Decides where to build. Returns
 * { buildRoot, substUsed, substNote, pathRisk }.
 */
function resolveBuildRoot() {
  const repoNonAscii = nonAscii(repoRoot);
  if (!repoNonAscii) {
    return {
      buildRoot: repoRoot,
      substUsed: false,
      substNote:
        "repo path is pure ASCII; the subst X: alias is not required (R5 mitigated by layout)",
      pathRisk: "none",
    };
  }

  const mapping = substMappings().find(
    (m) =>
      m.drive.toUpperCase() === SUBST_DRIVE &&
      (repoRoot.toLowerCase() === m.target.toLowerCase() ||
        repoRoot.toLowerCase().startsWith(m.target.toLowerCase() + "\\")),
  );
  if (mapping) {
    const aliased = SUBST_DRIVE + repoRoot.slice(mapping.target.length);
    return {
      buildRoot: aliased,
      substUsed: true,
      substNote: `non-ASCII repo path; building through ${SUBST_DRIVE}: -> ${mapping.target}`,
      pathRisk: "mitigated-by-subst",
    };
  }

  const asciiAncestor = (() => {
    let dir = repoRoot;
    while (nonAscii(dir)) {
      const parent = dirname(dir);
      if (parent === dir) return null;
      dir = parent;
    }
    return dir;
  })();
  const hint = asciiAncestor
    ? `  subst ${SUBST_DRIVE} "${asciiAncestor}"`
    : `  subst ${SUBST_DRIVE} "<some ASCII ancestor of the repo>"`;
  console.warn(
    `[build-smoke] WARNING: repo path contains non-ASCII characters and no usable\n` +
      `${SUBST_DRIVE}: subst mapping exists (R5: the release AOT snapshotter breaks\n` +
      `on non-ASCII paths). Fix for release builds:\n${hint}\n` +
      `(remove afterwards with: subst ${SUBST_DRIVE} /D)`,
  );
  if (wantRelease) {
    console.error(
      `[build-smoke] REFUSING release build without the subst alias (R5). Aborting.`,
    );
    process.exit(1);
  }
  console.warn(
    `[build-smoke] Policy: --debug continues at the real path (JIT build, no AOT\n` +
      `snapshotter). If this build fails with path errors, set up the alias above\n` +
      `and re-run.`,
  );
  return {
    buildRoot: repoRoot,
    substUsed: false,
    substNote: `non-ASCII repo path without a ${SUBST_DRIVE}: alias; debug build continued at the real path`,
    pathRisk: "non-ascii-without-subst",
  };
}

/** flutter --version summary for the manifest (machine JSON, text fallback). */
function flutterVersionSummary() {
  const machine = capture(flutterExe, ["--version", "--machine"]);
  try {
    const j = JSON.parse(machine);
    const channel = Array.isArray(j.channel)
      ? (j.channel[0] ?? null)
      : (j.channel ?? null);
    return {
      frameworkVersion: j.frameworkVersion ?? null,
      dartSdkVersion: j.dartSdkVersion ?? null,
      channel,
    };
  } catch {
    const lines = capture(flutterExe, ["--version"])
      .split(/\r?\n/)
      .filter((l) => l.trim())
      .slice(0, 2);
    return lines.length ? { text: lines.join(" | ") } : { text: "unknown" };
  }
}

async function sha256File(path) {
  const hash = createHash("sha256");
  await new Promise((res, rej) => {
    const stream = createReadStream(path);
    stream.on("data", (c) => hash.update(c));
    stream.on("end", res);
    stream.on("error", rej);
  });
  return hash.digest("hex");
}

const decision = resolveBuildRoot();
const flutterDir = join(decision.buildRoot, "flutter");

console.log(`[build-smoke] mode=${buildMode} substUsed=${decision.substUsed}`);
console.log(`[build-smoke] flutter: ${flutterExe}`);
console.log(`[build-smoke] building in: ${flutterDir}`);

const code = await run(flutterExe, ["build", "apk", `--${buildMode}`], {
  cwd: flutterDir,
});
if (code !== 0) {
  console.error(
    `[build-smoke] BUILD FAILED (exit ${code}). No manifest written.\n` +
      `  If the log mentions a missing Android SDK: set ANDROID_HOME / add\n` +
      `  platform-tools to PATH (or run: flutter doctor --android-licenses).\n` +
      `  If it mentions a missing JDK: set JAVA_HOME to a JDK 17+ install.\n` +
      `  If it mentions illegal path characters: see the subst hint above (R5).`,
  );
  process.exit(code);
}

const candidates = [
  join(flutterDir, "build", "app", "outputs", "flutter-apk", apkName),
  join(flutterDir, "build", "app", "outputs", "apk", buildMode, apkName),
];
let apkPath = null;
for (const c of candidates) {
  try {
    await stat(c);
    apkPath = c;
    break;
  } catch {
    // try next
  }
}
if (!apkPath) {
  console.error(
    `[build-smoke] build exited 0 but no APK found at the known output paths.\n` +
      `  checked: ${candidates.join(", ")}`,
  );
  process.exit(1);
}

const [info, sha256] = [await stat(apkPath), await sha256File(apkPath)];
const manifest = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  buildMode,
  substUsed: decision.substUsed,
  substNote: decision.substNote,
  pathRisk: decision.pathRisk,
  flutter: flutterVersionSummary(),
  artifact: {
    name: apkName,
    path: relative(repoRoot, apkPath).split("\\").join("/"),
    sizeBytes: info.size,
    sha256,
  },
};

await mkdir(artifactsDir, { recursive: true });
await writeFile(
  join(artifactsDir, "build-smoke.json"),
  JSON.stringify(manifest, null, 2) + "\n",
  "utf8",
);
console.log(`[build-smoke] OK ${apkName} (${info.size} bytes)`);
console.log(`[build-smoke] sha256=${sha256}`);
console.log(`[build-smoke] manifest: artifacts/build-smoke.json`);

// The APK itself is a build product (gitignored); only the manifest is
// meant for commit. Guard against future drift by listing what sits next
// to it, without failing the smoke.
const outDir = dirname(apkPath);
try {
  const names = (await readdir(outDir)).filter((n) => n.endsWith(".apk"));
  console.log(`[build-smoke] apks in output dir: ${names.join(", ")}`);
} catch {
  // informational only
}
