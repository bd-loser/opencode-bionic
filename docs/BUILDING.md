# Building on device / from source

## On your Termux phone

```bash
# 1. Prerequisites (one-time)
pkg update && pkg upgrade
pkg install git python build-essential clang make
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash

# 2. Clone + setup (fetches upstream, applies the delta, installs deps)
git clone https://github.com/bd-loser/opencode-bionic.git ~/opencode-bionic
cd ~/opencode-bionic
bash termux/setup.sh

# 3. Build + install the compiled binary
bash termux/rebuild-opencode.sh

opencode --version
```

## Patches

Every source delta lives in `termux/patches/` and must apply with
`patch -p1 --forward` to a shallow upstream clone. After an upstream
version bump breaks them, rebase:

```bash
bash termux/ci/prepare-build-tree.sh /tmp/refresh
cd /tmp/refresh
# fix conflicts, edit files, commit
git add -A && git commit --amend --no-edit
bash "$OLDPWD/termux/ci/refresh-patches.sh" /tmp/refresh
```

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full build pipeline.
