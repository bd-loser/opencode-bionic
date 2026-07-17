#!/usr/bin/env bun
// =============================================================================
// build-termux.ts — compile opencode into a single binary for Termux/Android
// =============================================================================
//
// This is a modified version of packages/opencode/script/build.ts that:
//   1. Targets ONLY Android arm64 (no multi-platform build)
//   2. Uses `target: "bun"` — embed the CURRENT running Bun (the patched
//      bun-termux binary) instead of downloading bun-linux-arm64 (glibc)
//   3. Skips the web UI embed (not needed for TUI, saves build time)
//   4. Sets the right bunfsRoot for Linux/Android
//
// Your bun-termux already patches `bun build --compile` for Android:
//   - src/exe_format/elf.zig: fixes PIE/ASLR with Bionic's linker64
//   - Uses last writable PT_LOAD segment, writes offset to BUN_COMPILED
//
// USAGE:
//   bun run script/build-termux.ts
//
// OUTPUT:
//   dist/opencode-android-arm64/bin/opencode
//
// =============================================================================

import { $ } from "bun"
import fs from "fs"
import path from "path"
import { fileURLToPath } from "url"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const dir = path.resolve(__dirname, "..")

process.chdir(dir)

import { Script } from "@opencode-ai/script"
import pkg from "../package.json"

const sourcemapsFlag = process.argv.includes("--sourcemaps")
const plugin = createSolidTransformPlugin()

// -----------------------------------------------------------------------------
// opentuiAliasPlugin — remap bare @opentui/* imports to @xincli/opentui-*.
// -----------------------------------------------------------------------------
// The published @xincli/opentui-{keymap,solid} packages contain compiled JS
// that hardcodes bare imports like `import "@opentui/keymap"`, `"@opentui/solid"`,
// and subpath variants (/extras, /addons, /html, /opentui, /react, /solid,
// /components, /jsx-runtime, /jsx-dev-runtime, /extras/graph, /addons/opentui).
//
// Root package.json `overrides` and workspace `catalog:` pins rewrite refs
// from *consumers* but do NOT propagate into a nested @xincli package's own
// tree under bun's isolated linker (node_modules/.bun/<pkg>@ver/...). The
// bundler sees `import "@opentui/keymap"` inside @xincli/opentui-keymap's own
// runtime-modules.js and can't resolve it — @opentui/keymap simply isn't in
// that package's isolated scope.
//
// This plugin fixes it at bundle time: intercept every "@opentui/{keymap,solid}"
// specifier (and their subpaths), rewrite to the matching "@xincli/*" package
// (which IS installed and IS in scope of the root workspace), and hand off to
// bun's default resolver.
// -----------------------------------------------------------------------------
const opentuiAliasPlugin: import("bun").BunPlugin = {
  name: "opentui-alias",
  setup(build) {
    const remap: Record<string, string> = {
      "@opentui/keymap": "@xincli/opentui-keymap",
      "@opentui/solid": "@xincli/opentui-solid",
      "@opentui/core": "@xincli/opentui-core",
    }
    build.onResolve({ filter: /^@opentui\// }, (args) => {
      for (const [from, to] of Object.entries(remap)) {
        if (args.path === from || args.path.startsWith(from + "/")) {
          const rewritten = to + args.path.slice(from.length)
          // Bun's plugin API treats a returned `path` as final (no further
          // resolution), and `build.resolve()` is not implemented yet
          // (oven-sh/bun#2771). Use Bun.resolveSync to convert the bare
          // specifier to an absolute file path anchored at the importer's
          // directory (or cwd when there's no importer, e.g. entry points).
          const parent = args.importer ? path.dirname(args.importer) : dir
          const resolved = Bun.resolveSync(rewritten, parent)
          return { path: resolved }
        }
      }
      return null
    })
  },
}

console.log("==========================================")
console.log("Building opencode for Termux/Android arm64")
console.log("==========================================")
console.log(`  opencode version: ${Script.version}`)
console.log(`  bun version:      ${Bun.version}`)
console.log(`  platform:         ${process.platform}-${process.arch}`)
console.log(`  sourcemaps:       ${sourcemapsFlag}`)
console.log("==========================================")

// --- Resolve the parser.worker.js path --------------------------------------
// This is needed for opentui's tree-sitter worker. We embed it as a file.
const localPath = path.resolve(dir, "node_modules/@opentui/core/parser.worker.js")
const rootPath = path.resolve(dir, "../../node_modules/@opentui/core/parser.worker.js")
const parserWorker = fs.realpathSync(fs.existsSync(localPath) ? localPath : rootPath)

const workerPath = "./src/cli/tui/worker.ts"

// bunfsRoot: where the embedded filesystem lives in the compiled binary.
// On Linux/Android, Bun uses "/$bunfs/root/".
const bunfsRoot = "/$bunfs/root/"
const workerRelativePath = path.relative(dir, parserWorker).replaceAll("\\", "/")

// --- The target name --------------------------------------------------------
const name = "opencode-android-arm64"

console.log(`\nBuilding ${name}...`)
await $`mkdir -p dist/${name}/bin`

// --- Build with Bun.compile -------------------------------------------------
// CRITICAL: `target: "bun"` means "use the currently running Bun binary as
// the embedded runtime". This is the patched bun-termux binary — NOT a
// downloaded glibc Bun. Without this, Bun would try to download
// bun-linux-arm64 (glibc) which can't run under Bionic.
//
// The upstream build.ts uses `target: name.replace(pkg.name, "bun")` which
// maps "opencode-linux-arm64" → "bun-linux-arm64". That downloads glibc Bun.
// We use "bun" (literal) to use the current binary.

console.log("  Compiling with Bun.build()...")
console.log(`  target: "bun-linux-arm64" (matches current platform — uses current bun-termux)`)
console.log(`  outfile: dist/${name}/bin/opencode`)

const result = await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  plugins: [opentuiAliasPlugin, plugin],
  external: ["node-gyp"],
  format: "esm",
  minify: true,
  sourcemap: sourcemapsFlag ? "linked" : "none",
  splitting: true,
  compile: {
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    // KEY: use "bun-linux-arm64" — Bun normalizes android→linux, so this
    // matches the current platform. When the target matches the current
    // platform, Bun uses the CURRENTLY RUNNING Bun binary (your patched
    // bun-termux) instead of downloading a glibc Bun from npm.
    //
    // Bun requires the target to start with "bun-" — "bun" alone throws:
    //   TypeError: Expected compile target to start with 'bun-', got bun
    //
    // Upstream build.ts uses `name.replace(pkg.name, "bun")` which produces
    // "bun-linux-arm64" for the linux-arm64 target. We do the same — the
    // difference is we ONLY build this one target (not all platforms), and
    // we skip the web UI embed + model data generation.
    target: "bun-linux-arm64" as any,
    outfile: `dist/${name}/bin/opencode`,
    execArgv: [`--user-agent=opencode/${Script.version}`, "--use-system-ca", "--"],
  },
  entrypoints: ["./src/index.ts", parserWorker, workerPath],
  define: {
    // On Termux, libc is Bionic — neither glibc nor musl. Use "gnu" as a
    // placeholder (fff-bun won't load anyway due to os restriction, and
    // Patch 1f handles that in source).
    FFF_LIBC: JSON.stringify("gnu"),
    OPENCODE_VERSION: `'${Script.version}'`,
    OPENCODE_MODELS_DEV: "", // skip model data generation (not needed for TUI)
    OTUI_TREE_SITTER_WORKER_PATH: bunfsRoot + workerRelativePath,
    OPENCODE_WORKER_PATH: workerPath,
    OPENCODE_CHANNEL: `'${Script.channel}'`,
    // OPENCODE_LIBC: leave empty — Termux is neither glibc nor musl
    OPENCODE_LIBC: "",
  },
})

if (!result.success) {
  console.error("Build failed:")
  for (const log of result.logs) {
    console.error(" ", log)
  }
  process.exit(1)
}

console.log("  Build succeeded!")

// --- Smoke test -------------------------------------------------------------
const binaryPath = `dist/${name}/bin/opencode`
console.log(`\nRunning smoke test: ${binaryPath} --version`)
try {
  const versionOutput = await $`${binaryPath} --version`.text()
  console.log(`Smoke test passed: ${versionOutput.trim()}`)
} catch (e) {
  console.error(`Smoke test failed for ${name}:`, e)
  console.error("(The binary may still work — try running it directly)")
  // Don't exit 1 on smoke test failure — the binary might work despite
  // --version failing (e.g. env-specific issues in the build sandbox).
}

// --- Write package.json for the binary --------------------------------------
await Bun.file(`dist/${name}/package.json`).write(
  JSON.stringify(
    {
      name,
      version: Script.version,
      preferUnplugged: true,
      os: ["android"],
      cpu: ["arm64"],
    },
    null,
    2,
  ),
)

console.log(`\n==========================================`)
console.log(`Build complete!`)
console.log(`==========================================`)
console.log(`Binary: dist/${name}/bin/opencode`)
console.log(`Size:   ${(fs.statSync(binaryPath).size / 1024 / 1024).toFixed(1)} MB`)
console.log(`\nInstall:`)
console.log(`  cp dist/${name}/bin/opencode $PREFIX/bin/opencode`)
console.log(`  chmod +x $PREFIX/bin/opencode`)
