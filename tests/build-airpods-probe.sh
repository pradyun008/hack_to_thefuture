#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tour_probe=/tmp/HouseTourAirPodsProbe.app
mkdir -p "$tour_probe/Contents/MacOS"
cat tests/AirPodsLiveProbe.swift > /tmp/house-tour-airpods-probe.swift
sed -n '/^final class HeadMotion:/,$p' HouseTour/HouseTour/AppModel.swift >> /tmp/house-tour-airpods-probe.swift
python3 - <<'PY'
from pathlib import Path
import plistlib
source = Path('HouseTour/HouseTour/SpatialAudio.swift').read_text()
start = source.index('    private lazy var warningBuffer = Synth.buffer(format, seconds: 0.12) { _, t in')
end = source.index('\n\n', start)
expression = source[start:end].replace('    private lazy var warningBuffer = ', '    return ', 1)
with Path('/tmp/house-tour-airpods-probe.swift').open('a') as output:
    output.write('\nfunc makeWallWarning(_ format: AVAudioFormat) -> AVAudioPCMBuffer {\n' + expression + '\n}\n')
    output.write(source[source.index('enum Synth {'):])
info = {'CFBundleIdentifier': 'com.edisonhui.housetour.airpodsprobe',
        'CFBundleExecutable': 'HouseTourAirPodsProbe', 'CFBundleName': 'HouseTourAirPodsProbe',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'NSMotionUsageDescription': 'Tests AirPods head turning for the HouseTour project.',
        'LSMinimumSystemVersion': '14.0'}
with Path('/tmp/HouseTourAirPodsProbe.app/Contents/Info.plist').open('wb') as output:
    plistlib.dump(info, output)
PY
swiftc -parse-as-library -module-cache-path /tmp/house-tour-probe-modules \
  /tmp/house-tour-airpods-probe.swift -o "$tour_probe/Contents/MacOS/HouseTourAirPodsProbe"
codesign --force --sign - "$tour_probe"
echo "$tour_probe"
