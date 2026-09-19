#!/usr/bin/env python3
"""Build/run the existing visual regressions using an isolated test library."""
from pathlib import Path
import os
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
source = root / 'Sources/NotchMusic'
build = root / '.build/ui-checks'
build.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(
    ['zsh', str(root / 'scripts/select-macos-sdk.sh')], text=True
).strip()
os.environ['CLANG_MODULE_CACHE_PATH'] = '/tmp/notchmusic-module-cache'
names = ['ArtworkPresentation', 'ChargingMorph', 'PlaybackMorph', 'PlayerExpansion', 'VolumePresentation', 'WarningMorph', 'ImmersivePlayer', 'CompactAlignment', 'MotionBrightness']
if '--run' not in sys.argv:
    sources = [str(p) for p in sorted(source.glob('*.swift')) if p.name != 'NotchMusicApp.swift']
    library = build / 'libNotchMusicCore.dylib'
    subprocess.run(['swiftc', '-parse-as-library', '-sdk', sdk, '-emit-library', '-emit-module',
        '-enable-testing', '-module-name', 'NotchMusicCore', '-emit-module-path', str(build / 'NotchMusicCore.swiftmodule'),
        *sources, '-o', str(library)], check=True, cwd=root)
    for name in names:
        test = (root / 'tests' / (name + 'Checks.swift')).read_text()
        test = test.replace('/tmp/notch-', str(root / '.build/gui-review/notch-'))
        generated = build / (name + 'Checks.swift')
        generated.write_text('@testable import NotchMusicCore\n' + test)
        subprocess.run(['swiftc', '-parse-as-library', '-sdk', sdk, '-I', str(build), '-L', str(build),
            '-lNotchMusicCore', '-Xlinker', '-rpath', '-Xlinker', str(build), str(generated), '-o', str(build / name)], check=True, cwd=root)
    print('PASS: visual test binaries built', flush=True)
else:
    selected = set(sys.argv[2:])
    for name in names:
        if selected and name not in selected: continue
        print('UI CHECK', name, flush=True)
        subprocess.run([str(build / name)], check=True, timeout=120, cwd=root)
