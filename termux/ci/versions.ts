#!/usr/bin/env bun
// Reads versions.json (the single source of truth for opencode-bionic
// releases) and either applies pinned versions to a target tree or
// checks that a tree already matches.
//
//   bun termux/ci/versions.ts apply                      # rewrite files in repo (README only, post-migration)
//   bun termux/ci/versions.ts apply --target <dir>       # rewrite files in an upstream clone
//   bun termux/ci/versions.ts check                      # exit non-zero if repo README drifted
//   bun termux/ci/versions.ts check --target <dir>       # exit non-zero if target drifted
//   bun termux/ci/versions.ts print                      # emit shell-eval'able KEY=VAL lines
//
// The "config delta" (root package.json cleanup, catalog aliases,
// optionalDependencies, plugin peer bumps) is expressed programmatically
// here rather than as a patch because the shape survives upstream
// reformatting. The "source delta" (bunfig.toml, fff.bun.ts,
// build-termux.ts) lives in termux/patches/ as unified diffs.

import { existsSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"

const REPO_ROOT = path.resolve(import.meta.dir, "..", "..")
const VERSIONS_FILE = path.join(REPO_ROOT, "versions.json")

type Versions = {
  opencode: string
  opentui: {
    core: string
    keymap: string
    solid: string
    react: string
    androidArm64Native: string
  }
  bunTermux: { installUrl: string }
}

const versions: Versions = JSON.parse(readFileSync(VERSIONS_FILE, "utf8"))

function readJson(file: string): any {
  return JSON.parse(readFileSync(file, "utf8"))
}

function writeJson(file: string, data: unknown) {
  writeFileSync(file, JSON.stringify(data, null, 2) + "\n")
}

type Check = { name: string; ok: boolean; msg: string; fix?: () => void }

// Every fix() re-reads the target file from disk before mutating. Multiple
// checks touch root package.json — if each captured its own `pkg` in a
// closure, the last write would clobber earlier edits.
function checkOpencodeVersion(target: string): Check | null {
  const file = path.join(target, "packages/opencode/package.json")
  if (!existsSync(file)) return null
  const cur = readJson(file).version
  const want = versions.opencode
  return {
    name: "packages/opencode/package.json version",
    ok: cur === want,
    msg: cur === want ? want : `${cur} → ${want}`,
    fix: () => {
      const pkg = readJson(file)
      pkg.version = want
      writeJson(file, pkg)
    },
  }
}

function checkPluginVersion(target: string): Check | null {
  const file = path.join(target, "packages/plugin/package.json")
  if (!existsSync(file)) return null
  const cur = readJson(file).version
  const want = versions.opencode
  return {
    name: "packages/plugin/package.json version",
    ok: cur === want,
    msg: cur === want ? want : `${cur} → ${want}`,
    fix: () => {
      const pkg = readJson(file)
      pkg.version = want
      writeJson(file, pkg)
    },
  }
}

function checkCatalogOpentui(target: string): Check | null {
  const file = path.join(target, "package.json")
  if (!existsSync(file)) return null
  const cat = readJson(file).workspaces?.catalog ?? {}
  const wantCore = `npm:@xincli/opentui-core@${versions.opentui.core}`
  const wantKm = `npm:@xincli/opentui-keymap@${versions.opentui.keymap}`
  const wantSolid = `npm:@xincli/opentui-solid@${versions.opentui.solid}`
  const drifted =
    cat["@opentui/core"] !== wantCore ||
    cat["@opentui/keymap"] !== wantKm ||
    cat["@opentui/solid"] !== wantSolid
  return {
    name: "root catalog opentui pins",
    ok: !drifted,
    msg: drifted
      ? `core=${cat["@opentui/core"]} keymap=${cat["@opentui/keymap"]} solid=${cat["@opentui/solid"]} → ${versions.opentui.core}`
      : `all @${versions.opentui.core}`,
    fix: () => {
      const pkg = readJson(file)
      pkg.workspaces ??= {}
      pkg.workspaces.catalog ??= {}
      pkg.workspaces.catalog["@opentui/core"] = wantCore
      pkg.workspaces.catalog["@opentui/keymap"] = wantKm
      pkg.workspaces.catalog["@opentui/solid"] = wantSolid
      writeJson(file, pkg)
    },
  }
}

function checkAndroidNative(target: string): Check | null {
  const file = path.join(target, "package.json")
  if (!existsSync(file)) return null
  const snap = readJson(file)
  const want = versions.opentui.androidArm64Native
  const curOverride = snap.overrides?.["@xincli/opentui-core-android-arm64"]
  const curOptional = snap.optionalDependencies?.["@xincli/opentui-core-android-arm64"]
  const drifted = curOverride !== want || curOptional !== want
  return {
    name: "root android-arm64 native pin",
    ok: !drifted,
    msg: drifted ? `override=${curOverride} optional=${curOptional} → ${want}` : `@${want}`,
    fix: () => {
      const pkg = readJson(file)
      pkg.overrides ??= {}
      pkg.optionalDependencies ??= {}
      pkg.overrides["@xincli/opentui-core-android-arm64"] = want
      pkg.optionalDependencies["@xincli/opentui-core-android-arm64"] = want
      writeJson(file, pkg)
    },
  }
}

// Root package.json cleanup: remove upstream install-time hooks and
// patched-dependency entries that don't apply on Termux.
//
//   - scripts.postinstall runs `bun run --cwd packages/core fix-node-pty`,
//     which needs node-pty native bindings we don't ship.
//   - scripts.prepare runs `husky`, which we don't install.
//   - trustedDependencies triggers native builds (esbuild, tree-sitter, etc.)
//     that either fail or aren't needed on Termux.
//   - patchedDependencies["@ff-labs/fff-bun@0.9.3"] references a patch
//     upstream carries — we swap fff-bun for a lazy require instead
//     (see termux/patches/0003-*).
function checkRootConfigCleanup(target: string): Check | null {
  const file = path.join(target, "package.json")
  if (!existsSync(file)) return null
  const pkg = readJson(file)
  const hasPostinstall = pkg.scripts?.postinstall !== undefined
  const hasPrepare = pkg.scripts?.prepare !== undefined
  const hasTrusted = Array.isArray(pkg.trustedDependencies) && pkg.trustedDependencies.length > 0
  const hasFffPatch = pkg.patchedDependencies?.["@ff-labs/fff-bun@0.9.3"] !== undefined
  const drifted = hasPostinstall || hasPrepare || hasTrusted || hasFffPatch
  const detail = [
    hasPostinstall && "postinstall",
    hasPrepare && "prepare",
    hasTrusted && `trustedDeps(${pkg.trustedDependencies.length})`,
    hasFffPatch && "fff-bun-patch",
  ]
    .filter(Boolean)
    .join(",")
  return {
    name: "root package.json cleanup (scripts/trustedDeps/patchedDeps)",
    ok: !drifted,
    msg: drifted ? `remove: ${detail}` : "clean",
    fix: () => {
      const p = readJson(file)
      if (p.scripts?.postinstall !== undefined) delete p.scripts.postinstall
      if (p.scripts?.prepare !== undefined) delete p.scripts.prepare
      if (Array.isArray(p.trustedDependencies) && p.trustedDependencies.length > 0) p.trustedDependencies = []
      if (p.patchedDependencies?.["@ff-labs/fff-bun@0.9.3"] !== undefined)
        delete p.patchedDependencies["@ff-labs/fff-bun@0.9.3"]
      writeJson(file, p)
    },
  }
}

// Rewrite @opentui/* refs across every workspace package.json.
//
// Preserves `npm:@xincli/opentui-*@…` alias shape everywhere it exists.
// Skips `catalog:` and `workspace:` sentinels — those already resolve via
// the root catalog we pinned above. Silently no-ops when the target has no
// package.json files (e.g. repo without an upstream clone attached).
async function applyOpentuiWorkspaces(target: string): Promise<number> {
  if (!existsSync(path.join(target, "package.json"))) return 0
  const SKIP_DIRS = new Set([".git", ".opencode", ".turbo", "dist", "node_modules"])
  const OPENTUI_KEYS = ["@opentui/core", "@opentui/keymap", "@opentui/solid"] as const
  const wantFor: Record<(typeof OPENTUI_KEYS)[number], string> = {
    "@opentui/core": versions.opentui.core,
    "@opentui/keymap": versions.opentui.keymap,
    "@opentui/solid": versions.opentui.solid,
  }
  const aliasFor: Record<(typeof OPENTUI_KEYS)[number], string> = {
    "@opentui/core": `npm:@xincli/opentui-core@${versions.opentui.core}`,
    "@opentui/keymap": `npm:@xincli/opentui-keymap@${versions.opentui.keymap}`,
    "@opentui/solid": `npm:@xincli/opentui-solid@${versions.opentui.solid}`,
  }

  const files = (await Array.fromAsync(new Bun.Glob("**/package.json").scan({ cwd: target }))).filter(
    (f) => !f.split("/").some((p) => SKIP_DIRS.has(p)),
  )

  let changed = 0
  const rewriteMap = (obj: unknown): boolean => {
    if (!obj || typeof obj !== "object") return false
    const map = obj as Record<string, unknown>
    let dirty = false
    for (const key of OPENTUI_KEYS) {
      const cur = map[key]
      if (typeof cur !== "string") continue
      if (cur === "catalog:" || cur.startsWith("workspace:")) continue
      let next: string
      if (cur.startsWith("npm:@xincli/opentui-")) {
        next = aliasFor[key]
      } else {
        const m = cur.match(/^([\^~]|>=)/)
        next = (m?.[0] ?? "") + wantFor[key]
      }
      if (next !== cur) {
        map[key] = next
        dirty = true
      }
    }
    return dirty
  }

  for (const rel of files) {
    const abs = path.join(target, rel)
    const pkg = readJson(abs)
    const dirty =
      rewriteMap(pkg.dependencies) ||
      rewriteMap(pkg.devDependencies) ||
      rewriteMap(pkg.peerDependencies) ||
      rewriteMap(pkg.workspaces?.catalog)
    if (dirty) {
      writeJson(abs, pkg)
      changed++
    }
  }
  return changed
}

// README always lives in the repo, never in an upstream target.
function applyReadme(): boolean {
  const README = path.join(REPO_ROOT, "README.md")
  if (!existsSync(README)) return false
  const orig = readFileSync(README, "utf8")
  const badges =
    `[![opentui-js](https://img.shields.io/badge/opentui--js-@xincli%40${versions.opentui.core}-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core)\n` +
    `[![opentui-so](https://img.shields.io/badge/libopentui.so-@xincli%40${versions.opentui.androidArm64Native}-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core-android-arm64)`
  const table =
    `| Component | Version |\n` +
    `|---|---|\n` +
    `| opencode (upstream) | \`${versions.opencode}\` |\n` +
    `| \`@opentui/{core,keymap,solid}\` (JS, via \`@xincli\`) | \`${versions.opentui.core}\` |\n` +
    `| \`@xincli/opentui-core-android-arm64\` (native \`.so\`) | \`${versions.opentui.androidArm64Native}\` |\n` +
    `| \`bun-termux\` runtime | tracked at [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) |`
  let out = orig.replace(
    /<!-- versions:badges -->[\s\S]*?<!-- \/versions:badges -->/,
    `<!-- versions:badges -->\n${badges}\n<!-- /versions:badges -->`,
  )
  out = out.replace(
    /<!-- versions:table -->[\s\S]*?<!-- \/versions:table -->/,
    `<!-- versions:table -->\n${table}\n<!-- /versions:table -->`,
  )
  if (out === orig) return false
  writeFileSync(README, out)
  return true
}

function parseArgs() {
  const args = process.argv.slice(2)
  const mode = args[0] ?? "check"
  let target = REPO_ROOT
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--target" && args[i + 1]) {
      target = path.resolve(args[++i]!)
    }
  }
  return { mode, target }
}

async function main() {
  const { mode, target } = parseArgs()

  if (mode === "print") {
    console.log(`OPENCODE_VERSION=${versions.opencode}`)
    console.log(`OPENTUI_CORE=${versions.opentui.core}`)
    console.log(`OPENTUI_KEYMAP=${versions.opentui.keymap}`)
    console.log(`OPENTUI_SOLID=${versions.opentui.solid}`)
    console.log(`OPENTUI_REACT=${versions.opentui.react}`)
    console.log(`OPENTUI_NATIVE_ANDROID_ARM64=${versions.opentui.androidArm64Native}`)
    console.log(`BUN_TERMUX_INSTALL_URL=${versions.bunTermux.installUrl}`)
    return
  }

  const checks = [
    checkOpencodeVersion(target),
    checkPluginVersion(target),
    checkCatalogOpentui(target),
    checkAndroidNative(target),
    checkRootConfigCleanup(target),
  ].filter((c): c is Check => c !== null)

  const drifted = checks.filter((c) => !c.ok)

  if (checks.length === 0) {
    console.log(`  (no package.json found at ${target === REPO_ROOT ? "repo root" : target}; only README will be checked)`)
  }
  for (const c of checks) {
    console.log(`  ${c.ok ? "✓" : "✗"} ${c.name}: ${c.msg}`)
  }

  if (mode === "check") {
    if (drifted.length) {
      console.error(`\nDrift detected in ${drifted.length} location(s). Run: bun termux/ci/versions.ts apply --target ${target}`)
      process.exit(1)
    }
    console.log("\nAll pins match versions.json")
    return
  }

  if (mode === "apply") {
    for (const c of drifted) c.fix?.()
    const wsChanged = await applyOpentuiWorkspaces(target)
    const readmeChanged = applyReadme()
    console.log(
      drifted.length
        ? `\nApplied ${drifted.length} fix(es) + refreshed ${wsChanged} workspace package.json file(s)${readmeChanged ? " + README.md" : ""}`
        : `\nNothing to fix; refreshed ${wsChanged} workspace package.json file(s)${readmeChanged ? " + README.md" : ""}`,
    )
    return
  }

  console.error(`Unknown mode: ${mode}. Use: apply | check | print`)
  process.exit(2)
}

await main()
