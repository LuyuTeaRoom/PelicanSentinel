#!/usr/bin/env python3
"""Copy an explicit public source manifest to a new directory, without Git history."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import shutil

ROOT_FILES = (
    '.gitignore', 'Package.swift', 'README.md', 'README.zh-CN.md', 'LICENSE',
    'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md',
)
PUBLIC_DOCS = (
    'docs/ARCHITECTURE.md', 'docs/CODEXBAR_REFERENCE.md',
    'docs/VALIDATION.md', 'docs/RELEASING.md', 'docs/ASSETS.md',
    'docs/images/menu-history.png', 'docs/images/menu-history-en.png',
)
SCRIPTS = (
    'scripts/build-app.sh', 'scripts/test.sh', 'scripts/make-icon.swift',
    'scripts/prepare-public-release.py', 'Tests/ReleaseTests/test_public_export.py',
)
GITHUB_FILES = (
    '.github/workflows/ci.yml', '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/feature_request.yml', '.github/pull_request_template.md',
)


def public_files(root: Path) -> list[Path]:
    selected = list(ROOT_FILES + PUBLIC_DOCS + SCRIPTS + GITHUB_FILES)
    for folder, pattern in [('Sources', '*.swift'), ('Tests', '*.swift')]:
        selected.extend(str(p.relative_to(root)) for p in (root / folder).rglob(pattern))
    selected.extend([
        'Resources/Info.plist', 'Resources/AppIcon.icns',
        'Resources/PelicanLogo.svg', 'Resources/MenuBarLogo.svg',
    ])
    paths = [root / item for item in sorted(set(selected))]
    for path in paths:
        if not path.is_file() or any(p.is_symlink() for p in [path, *path.parents] if p.is_relative_to(root)):
            raise ValueError(f'Missing file or symbolic link in public manifest: {path.relative_to(root)}')
        if not path.resolve().is_relative_to(root):
            raise ValueError(f'File escapes source root: {path.relative_to(root)}')
    return paths


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='New directory; existing paths are never overwritten')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    destination = args.destination.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        parser.error('Destination already exists; choose a new directory.')
    paths = public_files(root)
    destination.mkdir(parents=True, exist_ok=False)
    for path in paths:
        target = destination / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    manifest = {
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'files': [str(path.relative_to(root)) for path in paths],
        'excluded': ['.git/', 'artifacts/', 'dist/', '.build/', 'docs/crew/', 'docs/source/', 'private acceptance logs'],
    }
    (destination / 'release-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(f'Prepared {len(paths)} public files in {destination}')


if __name__ == '__main__':
    main()
