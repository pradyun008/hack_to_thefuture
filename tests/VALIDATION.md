# Validation — October 3, 2026

## Forward calibration

- Changed HeadMotion from incremental turns to absolute heading relative to the
  calibrated forward pose. Forward is zero radians, which the mobile arrow draws up.
- Added Settings → Calibrate forward and the matching native Mac probe control.
  The Debug Simulator bridge synchronizes recalibration with the real sensor
  using a new calibration token; older samples cannot undo a recenter request.
- Regression checks pass for automatic and manual zeroing, left/right signs,
  returning to neutral, yaw wrap, non-finite samples, sensor reference changes,
  stale callbacks, reconnects and denied permission.
- Both bundled houses preserve head direction across floor changes, route
  rejoining and tour teleports. House switching carries the head heading forward.
- Debug Simulator and unsigned Release iPhone builds pass after this update.
- Updated simulator installed and launched; AirPods direction section and
  Calibrate forward button are present in the Settings accessibility tree.
- Native Mac probe received more than 10,000 actual AirPods motion samples.
  Pressed Calibrate forward in both the probe and the mobile Settings UI;
  each changed the shared calibration token and recentered the actual sensor.
  Confirmed live simulator headings continue updating from the new reference.
  After the upgrade, over 2,000 bridge requests succeeded without any additional
  errors. Non-finite /heading input returned HTTP 400.
- Returned to the mobile map and visually confirmed the live avatar arrow.
  Wearer's straight-ahead pose confirmation is pending; use Calibrate forward
  while looking ahead to establish that personal pose.

The earlier probe's expected 400 responses during the app upgrade came from
the older simulator's delta-only bridge. The new builds both use /heading.

## Live simulator and connected AirPods demonstration

- Enabled Show map through the app's actual Settings UI and opened the live
  laptop viewer, showing the dashed route.
- Real horizontal swipe on the simulator left the avatar's position unchanged.
- Real upward drag moved from Foyer to Living room; viewer state updated.
- Connected AirPods Pro selected as the Mac audio output. The native Mac probe
  received thousands of actual headphone motion updates with Motion authorized.
- Debug Simulator loopback bridge forwarded more than 2,700 requests with zero
  reported bridge errors; actual simulator heading changed in response.
- Triggered the iPhone app's warning playback through the local bridge. Audible
  confirmation and head-turn direction confirmation from the wearer are pending.
- Debug Simulator and unsigned iPhone Release builds pass. The release binary
  contains no SimulatorMotionBridge. Invalid non-finite motion input returns 400.
- Regression suite passes after the bridge change.

The simulator cannot directly access Mac-connected AirPods sensors; the native
probe supplies them for this development demo. Physical iPhone pairing and
end-to-end hardware validation remain outstanding. Demo windows and tracking
are left running for the user; closing the probe stops Mac motion capture.

## Latest upstream integration

Updated `main` from `04a0c5a` to `305e322` (`Redesign laptop viewer without
changing tour behavior`). Local work was preserved before the pull and applied
without merge conflicts. The upstream single tour button and tutorial replay
in Settings are retained; removed room/floor/front-door controls stay removed.

Revalidated on the updated source:

- All desktop movement, wall-warning and head-motion regression checks pass.
- Debug iOS Simulator and unsigned Release iPhone builds pass.
- Updated app installed and launched on the iOS 26.5 test simulator; process
  remained alive after startup.
- Local `/state` endpoint responds with position, heading, house, room, rail
  state and tour state for the redesigned laptop viewer.
- Plists and git diff whitespace checks pass.

AirPods head controls, horizontal-drag removal, warning audio, and motion usage
permission survived the integration. Physical-device verification remains
excluded. A pre-pull Git stash remains as a backup of the earlier local work.

Toolchain: Xcode 27.0 (27A266a). First-launch components installed.
iOS 27.0 and iOS 26.5 Simulator runtimes downloaded.

## Passed

- Debug iOS Simulator build for arm64 and x86_64; signing disabled.
- Release iPhone build for arm64; signing disabled. This is compilation, not a distributable signed app.
- Built app contains NSMotionUsageDescription.
- `bash tests/run-regressions.sh`: both bundled houses, ignored horizontal drags,
  head direction preserved during rail movement and finger lift, warning reentry,
  exact one-foot threshold, fast wall approach/collision, retreat/reentry,
  free movement following the head-controlled heading.
- Actual HeadMotion controller with a Core Motion stand-in: yaw wraparound,
  reference-frame jump suppression, restart calibration, foreground reconnect,
  background reconnect stays paused, queued updates ignored after stop,
  denied permission status.
- Startup smoke check: installed and launched on a dedicated iPhone 17 simulator
  running iOS 26.5. Process remained alive after startup.
- Plist validation and git diff whitespace checks.

## Review fixes

- Removed the obsolete drag/lift heading calculation.
- Fixed an exact-radius grid search bug that could miss a wall at one foot.
- Removed a strong capture of AppModel from the head-motion status callback.
- Added explicit connection-status monitoring and lifecycle guards.
- Included warnings at initial position, floor changes and teleports, plus every
  0.1-foot movement sample; warning rearm requires more than 1.25 feet clearance.

## Limits

The simulator logged Apple audio converter, voice database and Core Motion
framework errors. Startup succeeds, but this check does not verify sound output.
The newer SDK also reports an existing Sendable warning in Speaker.swift and
an AppIntents metadata message; neither prevents the builds.

Physical iPhone testing remains excluded. AirPods motion was verified on this
Mac, while wearer confirmation remains pending for actual head-turn sign,
latency, motion authorization prompts, Bluetooth reconnection, warning audibility,
VoiceOver output and routing all still need verification on the intended hardware.
No changes have been committed or pushed to GitHub.
