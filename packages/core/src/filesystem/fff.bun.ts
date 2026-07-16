import type {
  DirItem,
  DirSearchResult,
  FileItem,
  GrepCursor,
  GrepMatch,
  GrepResult,
  InitOptions,
  MixedItem,
  MixedSearchResult,
  SearchResult,
} from "@ff-labs/fff-bun"

// opencode-bionic-patched [Patch 1f]: Lazy-load @ff-labs/fff-bun runtime value.
// Root cause: @ff-labs/fff-bun@0.9.4 has "os": ["darwin","linux","win32"] in
// its package.json. On Termux (process.platform === "android"), Bun's installer
// silently skips the package — it's never placed in node_modules. A static
// ESM import would throw "Cannot find module" at startup, crashing opencode
// before it can fall back to ripgrep.
// Fix: use require() (which can be try/caught) instead of a static import.
// If the package isn't installed, FileFinder is null and available() returns
// false — opencode's search.ts then uses the ripgrep fallback (existing behavior).
type FileFinderType = typeof import("@ff-labs/fff-bun")["FileFinder"]
let FileFinder: FileFinderType | null
try {
  FileFinder = require("@ff-labs/fff-bun").FileFinder
} catch {
  FileFinder = null
}

declare global {
  const FFF_LIBC: "gnu" | "musl"
}

export type Result<T> = { ok: true; value: T } | { ok: false; error: string }

export type Init = InitOptions

export interface Search {
  items: FileItem[]
  scores: SearchResult["scores"]
  totalMatched: number
  totalFiles: number
}

export interface DirSearch {
  items: DirItem[]
  scores: DirSearchResult["scores"]
  totalMatched: number
  totalDirs: number
}

export interface MixedSearch {
  items: MixedItem[]
  scores: MixedSearchResult["scores"]
  totalMatched: number
  totalFiles: number
  totalDirs: number
}

export type File = FileItem
export type Directory = DirItem
export type Mixed = MixedItem
export type Cursor = GrepCursor | null
export type Hit = GrepMatch

export interface Grep {
  items: GrepResult["items"]
  totalMatched: number
  totalFilesSearched: number
  totalFiles: number
  filteredFileCount: number
  nextCursor: Cursor
  regexFallbackError?: string
}

export interface Picker {
  destroy(): void
  isScanning(): boolean
  waitForScan(timeoutMs?: number): Promise<Result<boolean>>
  refreshGitStatus(): Result<number>
  fileSearch(
    query: string,
    opts?: {
      currentFile?: string
      pageIndex?: number
      pageSize?: number
    },
  ): Result<Search>
  glob(
    pattern: string,
    opts?: {
      currentFile?: string
      pageIndex?: number
      pageSize?: number
    },
  ): Result<Search>
  directorySearch(
    query: string,
    opts?: {
      currentFile?: string
      pageIndex?: number
      pageSize?: number
    },
  ): Result<DirSearch>
  mixedSearch(
    query: string,
    opts?: {
      currentFile?: string
      pageIndex?: number
      pageSize?: number
    },
  ): Result<MixedSearch>
  grep(
    query: string,
    opts?: {
      mode?: "plain" | "regex" | "fuzzy"
      maxMatchesPerFile?: number
      timeBudgetMs?: number
      beforeContext?: number
      afterContext?: number
      cursor?: Cursor
      pageSize?: number
    },
  ): Result<Grep>
  trackQuery(query: string, file: string): Result<boolean>
  getHistoricalQuery(offset: number): Result<string | null>
}

export function available() {
  // opencode-bionic-patched [Patch 1f]: null guard for missing @ff-labs/fff-bun
  if (!FileFinder) return false
  return FileFinder.isAvailable()
}

export function create(opts: Init): Result<Picker> {
  // opencode-bionic-patched [Patch 1f]: null guard for missing @ff-labs/fff-bun
  if (!FileFinder) return { ok: false, error: "fff-bun not installed on this platform (os restriction)" }
  const made = FileFinder.create(opts)
  if (!made.ok) return made
  const pick = made.value
  return {
    ok: true,
    value: {
      destroy: () => pick.destroy(),
      isScanning: () => pick.isScanning(),
      waitForScan: (timeoutMs) => pick.waitForScan(timeoutMs),
      refreshGitStatus: () => pick.refreshGitStatus(),
      fileSearch: (query, next) => pick.fileSearch(query, next),
      glob: (pattern, next) => pick.glob(pattern, next),
      directorySearch: (query, next) => pick.directorySearch(query, next),
      mixedSearch: (query, next) => pick.mixedSearch(query, next),
      grep: (query, next) => pick.grep(query, next),
      trackQuery: (query, file) => pick.trackQuery(query, file),
      getHistoricalQuery: (offset) => pick.getHistoricalQuery(offset),
    },
  }
}

export * as Fff from "./fff.bun"
