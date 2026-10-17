#!/usr/bin/env python3
"""Verify the release app, DMG checksum, signed bundle, and installer contents."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
dist = Path(os.environ.get('STUDIO_DIST_DIR', root / 'dist'))
version = (root / 'VERSION').read_text().strip()
number = (root / 'BUILD_NUMBER').read_text().strip()
app = dist / 'Launchpad Studio.app'
dmg = dist / f'Launchpad-Studio-{version}-universal.dmg'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def manifest(bundle):
    result = {}
    for path in bundle.rglob('*'):
        key = str(path.relative_to(bundle))
        if path.is_symlink():
            result[key] = ('link', os.readlink(path))
        elif path.is_file():
            result[key] = ('file', hashlib.sha256(path.read_bytes()).hexdigest(), bool(path.stat().st_mode & 0o111))
    return result

def verify_app(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == version
    assert info['CFBundleVersion'] == number
    assert info['LSMinimumSystemVersion'] == '13.0'
    assert (bundle / 'Contents/Resources/LICENSE.txt').read_bytes() == (root / 'LICENSE').read_bytes(), 'Missing or stale bundled license'
    binary = str(bundle / 'Contents/MacOS/LaunchpadStudio')
    assert set(run('xcrun', 'lipo', '-archs', binary).split()) == {'arm64', 'x86_64'}
    for arch in ('arm64', 'x86_64'):
        commands = run('xcrun', 'otool', '-l', '-arch', arch, binary)
        assert re.search(r'\bminos\s+13\.0\b', commands), f'{arch}: wrong minimum OS'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    for code in ('en', 'ko', 'ja', 'zh-Hans'):
        assert (bundle / f'Contents/Resources/{code}.lproj/Localizable.strings').is_file()
        privacy = bundle / f'Contents/Resources/{code}.lproj/InfoPlist.strings'
        descriptions = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(privacy)]))
        for key in ('NSAppleEventsUsageDescription', 'NSAppBundlesUsageDescription', 'NSAppDataUsageDescription'):
            assert info.get(key) and descriptions.get(key), f'{code}: missing {key}'

verify_app(app)
subprocess.run(['shasum', '-a', '256', '-c', dmg.name + '.sha256'], cwd=dist, check=True)
mounted = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-plist', str(dmg)]))
volume = next(Path(e['mount-point']) for e in mounted['system-entities'] if 'mount-point' in e)
try:
    contained = volume / app.name
    verify_app(contained)
    assert manifest(app) == manifest(contained), 'Mounted app differs from the build'
    assert sorted(p.name for p in volume.iterdir() if not p.name.startswith('.')) == ['Applications', app.name]
    assert (volume / 'Applications').is_symlink()
    assert os.readlink(volume / 'Applications') == '/Applications'
    print('PASS: Universal binaries, macOS 13 minimum, version, MIT license, four languages, strict signature, checksum, and complete DMG bundle match.')
finally:
    subprocess.run(['hdiutil', 'detach', str(volume)], check=True)
