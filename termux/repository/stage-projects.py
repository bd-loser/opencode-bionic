#!/usr/bin/env python3
"""Import release packages into all APT suites. Failure prevents deployment."""
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def field(path, name):
    return run('dpkg-deb', '-f', str(path), name)


def validate(path, package):
    if field(path, 'Package') != package or field(path, 'Architecture') != 'aarch64':
        raise ValueError(f'Unexpected package identity: {path}')
    subprocess.run(['dpkg', '--validate-version', field(path, 'Version')], check=True)


def main():
    # Termux may use umask 077; package payloads must remain readable.
    os.umask(0o022)
    projects = json.loads(Path(__file__).with_name('projects.json').read_text())
    names = set()
    with tempfile.TemporaryDirectory(prefix='termux-packages-') as scratch:
        for project in projects:
            name = project['package']
            if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]+', name) or name in names:
                raise ValueError(f'Invalid or duplicate package: {name}')
            names.add(name)
            work = Path(scratch) / name
            work.mkdir()
            repository, release = project['repository'], project['release']
            info = json.loads(run('gh', 'release', 'view', release, '-R', repository, '--json', 'assets'))
            assets = [a for a in info['assets'] if fnmatch.fnmatchcase(a['name'], project['asset'])]
            if not assets:
                raise ValueError(f'No release assets for {name}')
            packages = []
            for asset in assets:
                filename = asset['name']
                if Path(filename).name != filename:
                    raise ValueError('Invalid asset filename')
                run('gh', 'release', 'download', release, '-R', repository, '-p', filename, '-D', str(work))
                source = work / filename
                digest = project.get('sha256') or (asset.get('digest') or '').removeprefix('sha256:')
                if not digest:
                    run('gh', 'release', 'download', release, '-R', repository, '-p', filename + '.sha256', '-D', str(work))
                    digest = (work / (filename + '.sha256')).read_text().split()[0]
                if not re.fullmatch('[0-9a-f]{64}', digest) or hashlib.sha256(source.read_bytes()).hexdigest() != digest:
                    raise ValueError(f'Checksum mismatch: {filename}')
                if project['format'] == 'binary-tar':
                    stage = work / 'stage'
                    bindir = stage / 'data/data/com.termux/files/usr/bin'
                    bindir.mkdir(parents=True)
                    with tarfile.open(source) as archive:
                        for binary in project['binaries']:
                            if not re.fullmatch('[a-z0-9-]+', binary):
                                raise ValueError('Invalid binary name')
                            members = [m for m in archive.getmembers() if m.name.removeprefix('./') == binary]
                            if len(members) != 1 or not members[0].isfile():
                                raise ValueError(f'Missing or unsafe binary: {binary}')
                            with archive.extractfile(members[0]) as src, (bindir / binary).open('wb') as dst:
                                shutil.copyfileobj(src, dst)
                            (bindir / binary).chmod(0o755)
                    control = stage / 'DEBIAN'
                    control.mkdir()
                    size = sum(p.stat().st_size for p in bindir.iterdir())
                    (control / 'control').write_text(
                        f"Package: {name}\nVersion: {project['version']}\nArchitecture: aarch64\n"
                        f"Maintainer: bd-loser <bd-loser@users.noreply.github.com>\n"
                        f"Installed-Size: {(size + 1023) // 1024}\nSection: utils\nPriority: optional\n"
                        f"Homepage: https://github.com/{repository}\nDescription: {project['description']}\n")
                    source = work / f"{name}_{project['version']}_aarch64.deb"
                    run('dpkg-deb', '--root-owner-group', '-Zxz', '--build', str(stage), str(source))
                elif project['format'] != 'deb':
                    raise ValueError('Unsupported package format')
                validate(source, name)
                packages.append(source)
            newest = packages[0]
            for candidate in packages[1:]:
                result = subprocess.run(['dpkg', '--compare-versions', field(candidate, 'Version'), 'gt', field(newest, 'Version')])
                if result.returncode not in (0, 1):
                    raise ValueError('Invalid package version')
                if result.returncode == 0:
                    newest = candidate
            for channel in ('stable', 'v1', 'dev'):
                target = Path('pool') / channel
                target.mkdir(parents=True, exist_ok=True)
                shutil.copy2(newest, target / newest.name)
            print(f"Staged {name} {field(newest, 'Version')} in stable, v1, dev", flush=True)


if __name__ == '__main__':
    main()
