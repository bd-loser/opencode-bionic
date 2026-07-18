#!/usr/bin/env bun
// Reads versions.json (the single source of truth for opencode-bionic
// releases) and either applies the pinned versions to the workspace or
// checks that everything already matches.
//
//   bun termux/ci/versions.ts apply   # rewrite package.json files in place
//   bun termux/ci/versions.ts check   # exit non-zero on drift (for CI)
//   bun termux/ci/versions.ts print   # emit shell-eval'able KEY=VAL lines

import { readFileSync, writeFileSync } from "node:fs"
import path from "node:path"

const ROOT = path.resolve(import.meta.dir, "..", "..")
const VERSIONS_FILE = path.join(ROOT, "versions.json")
const OPENCODE_PKG = path.join(ROOT, "packages/opencode/package.json")
const ROOT_PKG = path.join(ROOT, "package.json")

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

// Returns [ok, description]. On apply, also mutates state.
type Check = { name: string; ok: boolean; msg: string; fix?: () => void }

function checkOpencodeVersion(): Check {
  const pkg = readJson(OPENCODE_PKG)
  const cur = pkg.version
  const want = versions.opencode
  return {
    name: "packages/opencode/package.json version",
    ok: cur === want,
    msg: cur === want ? want : `${cur} → ${want}`,
    fix: () => {
      pkg.version = want
      writeJson(OPENCODE_PKG, pkg)
    },
  }
}

function checkCatalogOpentui(): Check {
  const pkg = readJson(ROOT_PKG)
  const cat = pkg.workspaces?.catalog ?? {}
  const wantCore = `npm:@xincli/opentui-core@${versions.opentui.core}`
  const wantKm = `npm:@xincli/opentui-keymap@${versions.opentui.keymap}`
  const wantSolid = `npm:@xincli/opentui-solid@${versions.opentui.solid}`
  const drifted =
    cat["@opentui/core"] !== wantCore ||
    cat["@opentui/keymap"] !== wantKm ||
    cat["@opentui/solid"] !== wantSolid
  return {
    name: "root package.json catalog opentui pins",
    ok: !drifted,
    msg: drifted
      ? `core=${cat["@opentui/core"]} keymap=${cat["@opentui/keymap"]} solid=${cat["@opentui/solid"]} → ${versions.opentui.core}`
      : `all @${versions.opentui.core}`,
    fix: () => {
      cat["@opentui/core"] = wantCore
      cat["@opentui/keymap"] = wantKm
      cat["@opentui/solid"] = wantSolid
      writeJson(ROOT_PKG, pkg)
    },
  }
}

function checkAndroidNative(): Check {
  const pkg = readJson(ROOT_PKG)
  const want = versions.opentui.androidArm64Native
  const curOverride = pkg.overrides?.["@xincli/opentui-core-android-arm64"]
  const curOptional = pkg.optionalDependencies?.["@xincli/opentui-core-android-arm64"]
  const drifted = curOverride !== want || curOptional !== want
  return {
    name: "root package.json android-arm64 native pin",
    ok: !drifted,
    msg: drifted ? `override=${curOverride} optional=${curOptional} → ${want}` : `@${want}`,
    fix: () => {
      pkg.overrides ??= {}
      pkg.optionalDependencies ??= {}
      pkg.overrides["@xincli/opentui-core-android-arm64"] = want
      pkg.optionalDependencies["@xincli/opentui-core-android-arm64"] = want
      writeJson(ROOT_PKG, pkg)
    },
  }
}

// Rewrite @opentui/* refs across every workspace package.json.
//
// We do NOT delegate to upstream script/upgrade-opentui.ts because it
// (a) strips `npm:@xincli/opentui-*@…` aliases back to plain versions,
// which breaks the catalog pin that makes the Termux build work, and
// (b) runs `bun install` unconditionally, which fails offline / in CI
// preflight. Instead, walk the tree ourselves and preserve the alias
// shape everywhere it already exists.
async function applyOpentuiWorkspaces(): Promise<number> {
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

  const files = (await Array.fromAsync(new Bun.Glob("**/package.json").scan({ cwd: ROOT }))).filter(
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
      // Preserve the `npm:@xincli/opentui-*@…` alias shape when present.
      // Otherwise use the bare version (with any existing ^/~/>= prefix).
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
    const abs = path.join(ROOT, rel)
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

function applyReadme(): boolean {
  const README = path.join(ROOT, "README.md")
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

async function main() {
  const mode = process.argv[2] ?? "check"

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

  const checks = [checkOpencodeVersion(), checkCatalogOpentui(), checkAndroidNative()]
  const drifted = checks.filter((c) => !c.ok)

  for (const c of checks) {
    console.log(`  ${c.ok ? "✓" : "✗"} ${c.name}: ${c.msg}`)
  }

  if (mode === "check") {
    if (drifted.length) {
      console.error(`\nDrift detected in ${drifted.length} location(s). Run: bun termux/ci/versions.ts apply`)
      process.exit(1)
    }
    console.log("\nAll pins match versions.json")
    return
  }

  if (mode === "apply") {
    for (const c of drifted) c.fix?.()
    const wsChanged = await applyOpentuiWorkspaces()
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
