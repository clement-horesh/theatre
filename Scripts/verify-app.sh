#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
    printf 'Usage: bash Scripts/verify-app.sh /path/to/Theatre.app\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$1"
python3 - "$1" <<'PY'
from pathlib import Path
import plistlib, re, subprocess, sys

app = Path(sys.argv[1]).resolve()
with (app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
ats = info.get('NSAppTransportSecurity', {})
overrides = ('NSAllowsArbitraryLoadsForMedia', 'NSAllowsArbitraryLoadsInWebContent', 'NSAllowsLocalNetworking')
if ats.get('NSAllowsArbitraryLoads') is not True or any(key in ats for key in overrides):
    raise SystemExit('Jellyfin certificate exceptions require NSAllowsArbitraryLoads without overriding ATS keys.')
binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
rpaths = []
is_rpath = False
for line in commands.splitlines():
    if line.strip().startswith('cmd '):
        is_rpath = line.strip() == 'cmd LC_RPATH'
    if is_rpath:
        match = re.match(r'\s*path (.+) \(offset \d+\)', line)
        if match:
            rpaths.append(match.group(1))
if '@executable_path/../Frameworks' not in rpaths:
    raise SystemExit('Missing app Frameworks runtime search path; Sparkle cannot load in the packaged app.')

def expand(path):
    return Path(path.replace('@executable_path', str(binary.parent)).replace('@loader_path', str(binary.parent)))

libraries = subprocess.check_output(['otool', '-L', str(binary)], text=True)
for line in libraries.splitlines():
    match = re.match(r'\s+(.+?) \(compatibility version', line)
    if not match:
        continue
    name = match.group(1)
    if name.startswith(('/System/Library/', '/usr/lib/')):
        continue
    if name.startswith('@rpath/'):
        candidates = [expand(path) / name.removeprefix('@rpath/') for path in rpaths]
    else:
        candidates = [expand(name)]
    # Bundled dependencies must resolve inside this app, not in an Xcode or build folder.
    if not any(path.is_file() and path.resolve().is_relative_to(app) for path in candidates):
        raise SystemExit(f'Unresolved bundled library: {name}')
print('Verified app signature and bundled framework search paths.')
PY
