#!/usr/bin/env python3
"""Build a Maprisma Playground release: dist/maprisma-playground-<version>-x86_64.tar.gz and its SHA-256
(after Maprisma Launcher's tools/build-release.py).

The generated files checked against their sources (tools/gen-translations.py),
the Flutter app, the core CLI and the bar icons (COSMIC applet, KDE/Hyprland tray) built from a clean
copy (release mode), the release identity checked, and one folder maprisma-playground-<version>/ with:
    app/                      the bundle (maprisma-playground, lib/, data/, bin/ with
                              maprisma-playground-core, -applet and -tray)
    share/applications/       com.maprisma.Playground.desktop, the COSMIC applet's entry
    share/icons/hicolor/scalable/apps/   the app icon and the symbolic bar icons
    share/autostart/          com.maprisma.Playground.Tray.desktop (the tray, KDE Plasma and Hyprland)
    LICENSE
The AppImage is made from it (packaging/build-appimage.py).

    tools/build-release.py
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.maprisma.Playground'
APPLET_ID = 'io.github.ubruckhaus.CosmicMaprismaPlayground'
BINARY = 'maprisma-playground'
SKIP = shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', '.flutter-plugins*', 'target')


def version() -> str:
    found = re.search(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)', (ROOT / 'flutter_app/pubspec.yaml').read_text(), re.M)
    if not found:
        sys.exit('no version in flutter_app/pubspec.yaml')
    return found.group(1)


def check_generated():
    """The generated catalogs are committed: building them again must change nothing."""
    for tool in ('gen-translations.py',):
        subprocess.run([sys.executable, str(ROOT / 'tools' / tool)], check=True, stdout=subprocess.DEVNULL)
    changed = subprocess.run(['git', 'status', '--porcelain', '--', 'packages'], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.strip()
    if changed:
        sys.exit(f'generated files were out of date (commit them first):\n{changed}')


def check_identity(stage: Path):
    cmake = (stage / 'linux/CMakeLists.txt').read_text()
    if f'set(APPLICATION_ID "{APP_ID}")' not in cmake or f'set(BINARY_NAME "{BINARY}")' not in cmake:
        sys.exit('Unexpected application id or binary name in linux/CMakeLists.txt')


def put(source: Path, target: Path):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def main():
    ver = version()
    check_generated()
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-', dir=dist) as temp:
        stage = Path(temp) / 'flutter_app'
        shutil.copytree(ROOT / 'flutter_app', stage, ignore=SKIP)
        shutil.copytree(ROOT / 'packages', stage.parent / 'packages', ignore=SKIP)
        shutil.copytree(ROOT / 'bar', stage.parent / 'bar', ignore=SKIP)
        check_identity(stage)
        command = ['flutter', '--suppress-analytics', '--no-version-check']
        subprocess.run([*command, 'pub', 'get', '--offline'], cwd=stage, check=True)
        subprocess.run([*command, 'build', 'linux', '--release', '--no-pub', '--no-tree-shake-icons'],
                       cwd=stage, check=True)
        bundle = stage / 'build/linux/x64/release/bundle'
        if not (bundle / BINARY).is_file():
            sys.exit(f'no {BINARY} in the bundle')
        (bundle / 'bin').mkdir(exist_ok=True)
        core = stage.parent / 'packages/maprisma_playground_core'
        subprocess.run(['dart', 'pub', 'get', '--offline'], cwd=core, check=True)
        subprocess.run(['dart', 'compile', 'exe', 'bin/maprisma_playground_core.dart',
                        '-o', str(bundle / 'bin/maprisma-playground-core')], cwd=core, check=True)
        # The checkout's target folder as cache; only the copy's sources are built.
        env = {**os.environ, 'CARGO_TARGET_DIR': str(ROOT / 'bar/target')}
        subprocess.run(['cargo', 'build', '--release', '--locked', '--offline'],
                       cwd=stage.parent / 'bar', env=env, check=True)
        for part in ('applet', 'tray'):
            shutil.copy2(ROOT / f'bar/target/release/maprisma-playground-{part}', bundle / 'bin')
        top = Path(temp) / f'{BINARY}-{ver}'
        shutil.copytree(bundle, top / 'app', symlinks=True)
        share = top / 'share'
        put(ROOT / f'data/{APP_ID}.desktop', share / f'applications/{APP_ID}.desktop')
        put(ROOT / f'data/{APPLET_ID}.desktop', share / f'applications/{APPLET_ID}.desktop')
        put(ROOT / f'data/{APP_ID}.Tray.desktop', share / f'autostart/{APP_ID}.Tray.desktop')
        for icon in (f'{APP_ID}.svg', f'{APPLET_ID}-symbolic.svg', f'{APPLET_ID}-active-symbolic.svg'):
            put(ROOT / f'data/icons/{icon}', share / f'icons/hicolor/scalable/apps/{icon}')
        shutil.copy2(ROOT / 'LICENSE', top / 'LICENSE')
        archive = dist / f'{BINARY}-{ver}-x86_64.tar.gz'

        def owned(info):          # root-owned in any package made from it, no build user's names
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            return info
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(top, arcname=top.name, filter=owned)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / f'{archive.name}.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'\n{archive}\nsha256 {digest}')


if __name__ == '__main__':
    main()
