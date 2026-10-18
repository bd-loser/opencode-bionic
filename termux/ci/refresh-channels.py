#!/usr/bin/env python3
"""Refresh the per-line build table in README.md on every released branch.

Called by opencode.yml after each real release. Picks the newest release
per channel (stable = no suffix, beta/dev = <sha8> suffix), renders the
``<!-- versions:channels -->`` block, and pushes it to main/beta/dev via
the contents API. Deterministic output -> last-write-wins races converge.
DRY_RUN=1 prints instead of pushing.
"""

import base64
import json
import os
import re
import subprocess

REPO = os.environ["REPO"]
DRY = os.environ.get("DRY_RUN") == "1"
BLOCK_RE = re.compile(r"<!-- versions:channels -->.*?<!-- /versions:channels -->", re.S)
ANCHOR = "<!-- /versions:table -->"
RELEASES_URL = f"https://github.com/{REPO}/releases/tag/{{}}"
PATTERNS = {
    "stable": re.compile(r"^v\d+\.\d+\.\d+$"),
    "beta": re.compile(r"^v.*-beta\.[0-9a-f]{8}$"),
    "dev": re.compile(r"^v.*-dev\.[0-9a-f]{8}$"),
}


def sh(*args, stdin=None):
    return subprocess.run(args, capture_output=True, text=True, input=stdin, check=False)


def latest_tags():
    out = sh("gh", "release", "list", "-R", REPO, "-L", "80", "--json", "tagName",
             "--jq", ".[].tagName")
    if out.returncode:
        raise SystemExit(f"release list failed: {out.stderr}")
    tags = {}
    for tag in out.stdout.split():
        for name, pat in PATTERNS.items():
            if name not in tags and pat.match(tag):
                tags[name] = tag
    return tags


def render(tags):
    lines = ["| Line | Latest build |", "|---|---|"]
    for name in ("stable", "beta", "dev"):
        tag = tags.get(name)
        if not tag:
            lines.append(f"| **{name}** | *(not built yet)* |")
            continue
        ver = tag[1:]
        branch = "main" if name == "stable" else name
        lines.append(
            f"| **[{name}](https://github.com/{REPO}/tree/{branch})** "
            f"| [`{ver}`]({RELEASES_URL.format(tag)}) |"
        )
    body = "\n".join(lines)
    return f"<!-- versions:channels -->\n{body}\n<!-- /versions:channels -->"


def main():
    tags = latest_tags()
    block = render(tags)
    summary = " / ".join(tags.get(n, "?") for n in ("stable", "beta", "dev"))
    print(f"lines: {summary}")
    for branch in ("main", "beta", "dev"):
        get = sh("gh", "api", f"repos/{REPO}/contents/README.md?ref={branch}")
        if get.returncode:
            print(f"{branch}: fetch failed, skipped")
            continue
        doc = json.loads(get.stdout)
        cur = base64.b64decode(doc["content"]).decode()
        if BLOCK_RE.search(cur):
            new = BLOCK_RE.sub(lambda m: block, cur, count=1)
        elif ANCHOR in cur:
            new = cur.replace(ANCHOR, ANCHOR + "\n\n" + block, 1)
        else:
            print(f"{branch}: no anchor, skipped")
            continue
        if new == cur:
            print(f"{branch}: already current")
            continue
        if DRY:
            print(f"{branch}: would update")
            continue
        body = {
            "message": f"docs: per-line builds -> {summary}",
            "content": base64.b64encode(new.encode()).decode(),
            "sha": doc["sha"],
            "branch": branch,
        }
        put = sh("gh", "api", "-X", "PUT", f"repos/{REPO}/contents/README.md",
                 "--input", "-", stdin=json.dumps(body))
        print(f"{branch}: {'updated' if put.returncode == 0 else 'push failed'}")


if __name__ == "__main__":
    main()
