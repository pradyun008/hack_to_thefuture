#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tour_sdk="${1:-$(xcrun --sdk macosx --show-sdk-path)}"
tour_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/house-tour-tests.XXXXXX")"
swiftc -sdk "$tour_sdk" -module-cache-path "$tour_build_dir/modules" \
  HouseTour/HouseTour/House.swift HouseTour/HouseTour/Rail.swift \
  HouseTour/HouseTour/Explorer.swift tests/ExplorerRegression.swift \
  -o "$tour_build_dir/regression"
"$tour_build_dir/regression"
cat tests/HeadMotionRegression.swift > "$tour_build_dir/head-motion.swift"
sed -n '/^final class HeadMotion:/,$p' HouseTour/HouseTour/AppModel.swift >> "$tour_build_dir/head-motion.swift"
swiftc -parse-as-library -sdk "$tour_sdk" -module-cache-path "$tour_build_dir/modules" \
  "$tour_build_dir/head-motion.swift" -o "$tour_build_dir/head-motion"
"$tour_build_dir/head-motion"
