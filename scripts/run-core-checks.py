#!/usr/bin/env python3
"""Run deterministic regression checks without launching the player's UI."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / 'Sources/NotchMusic'
build = root / '.build/checks'
build.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(
    ['zsh', str(root / 'scripts/select-macos-sdk.sh')], text=True
).strip()
os.environ['CLANG_MODULE_CACHE_PATH'] = '/tmp/notchmusic-module-cache'
cases = {
    'WaveformAnalysisPolicy': ['WaveformAnalysisPolicy'],
    'YouTubeBrowser': ['YouTubeBrowserPlayback'],
    'BridgeProcess': ['BridgeProcessRunner'],
    'BridgeLineBuffer': ['NowPlayingStream', 'BridgeProcessRunner'],
    'BatteryLevelTracker': ['BatteryAlertInterval'],
    'LowBattery': ['LowBatteryPolicy', 'BatteryAlertInterval', 'AppLanguage'],
    'LowPowerMode': ['LowPowerModeController'],
    'LegacyPreferencesMigration': ['LegacyPreferencesMigration'],
    'ArtworkPalette': ['ArtworkPalette'],
    'NotchAlertSizing': ['NotchAlertSizing'],
    'NotchSurface': ['PlayerSurfaceShape', 'PlayerPresentationStyle'],
    'PresentationIcon': ['PlayerPresentationStyle'],
    'PlaybackQueue': ['PlaybackQueueClient', 'QueueArtwork'],
    # LyricsChecks exercises ImmersivePlayerModel and MediaRemoteClient too.
    # Compile the complete app core so this list cannot silently fall behind
    # their transitive dependencies again.
    'Lyrics': None,
    'VolumeKey': ['VolumeKeyInterceptor', 'OutputVolumeMonitor'],
}
import sys
selected = set(sys.argv[1:])
for name, dependencies in cases.items():
    if selected and name not in selected: continue
    binary = build / name
    selected_sources = (
        [item for item in sorted(source.glob('*.swift')) if item.name != 'NotchMusicApp.swift']
        if dependencies is None
        else [source / (item + '.swift') for item in dependencies]
    )
    command = ['swiftc', '-parse-as-library', '-sdk', sdk,
               *[str(item) for item in selected_sources],
               str(root / 'tests' / (name + 'Checks.swift')), '-o', str(binary)]
    print('CHECK', name, flush=True)
    subprocess.run(command, check=True, cwd=root)
    subprocess.run([str(binary)], check=True, timeout=30, cwd=root)
