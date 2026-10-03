# hack_to_thefuture

House Tour: an iPhone app that lets a blind home buyer explore a real listing's
floor plan by touch, with haptics for what the avatar walks over and spatial audio
for direction. The default demo house is 2011 O'Donnell Dr, Champaign, IL. A
second one, the Waterville plan, can be picked in settings. See
[DESIGN.md](DESIGN.md) for the haptic and audio vocabulary.

## Run it on an iPhone

Haptics only work on a real device.

1. Plug the iPhone in with a cable, unlock it, and tap Trust if asked. Developer
   Mode must be on (Settings > Privacy & Security > Developer Mode).
2. Open `HouseTour/HouseTour.xcodeproj` in Xcode, pick the phone as the run
   destination, and press Run. Signing uses team `9XPPP9TMHQ`; change
   `DEVELOPMENT_TEAM` in `HouseTour/project.yml` for another account and run
   `xcodegen generate` in `HouseTour/`.
3. First launch plays the haptic tutorial, then the guided tour. Plug in
   headphones to hear the front door chime in 3D.

From the command line instead:

```sh
cd HouseTour
xcodebuild -project HouseTour.xcodeproj -scheme HouseTour -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device id from `xcrun devicectl list devices`> \
  build/Build/Products/Debug-iphoneos/HouseTour.app
```

## Controls

The screen is a trackpad, and the map is hidden. Your avatar starts at the head
of the path, just inside the front door, facing into the house.

By default you're **on the path**: a fixed route through every room, so there's
nowhere to get lost. Drag along it to walk, drag back to retrace. A double tap
steps off it when you want to feel a room out for yourself, and another double
tap puts you back on at the nearest point.

- Drag one finger: walk. The avatar moves by how far the finger moves, not to
  where it is. Lifting and touching again never moves you. Walls stop you, and
  keep knocking while you push into them.
- Wear motion-capable AirPods Pro, select them as the iPhone audio output, and
  allow Motion access when prompted. Turn your head left/right to turn the
  avatar. Horizontal drags never move or rotate it.
- Look straight ahead and tap **Settings → Calibrate forward**. This pose
  points the map arrow straight up (heading zero). Turning left/right rotates
  relative to it; returning to forward points up again. Tour restarts, route
  rejoining, floor changes and house changes preserve the calibrated direction.
  The first motion sample also establishes forward; recalibrate after reconnecting
  or changing your seated direction.
- On the path, drag up to follow the route and down to retrace it, regardless
  of where you look. Off the path, up walks in your head-controlled direction
  and down walks backward. Lifting does not change your heading.
- A 120 ms, 2.4 kHz beep sounds on entering the one-foot zone around blocking
  geometry. It rearms after moving more than 1.25 feet away, so it does not
  continuously squeal beside a wall. This measures virtual geometry only.
- Narration, ambience, beacon and warning use the iPhone's selected audio route;
  with AirPods selected, they play through AirPods. VoiceOver announcements
  follow the system VoiceOver audio route.
- Single tap: which room you're in. During the guided tour, the way to the next
  stop.
- Double tap: leave the path, or rejoin it at the nearest point.
- Triple tap: where you are. The room, how close you are to a wall, and the
  nearest door and where it goes.
- Hold still on the stairs, finger down, for about a second: change floors. On
  the path this hands you to the next storey's stretch of the route.
- Taps and buttons never cut off speech. If something is being said, the
  request is skipped; ask again when it's quiet.
- One button: guided tour, which becomes "Stop tour" while it runs. The gear
  opens settings, with a switch for each sound, vibration, and spoken cue,
  fine movement, "Show map" for people watching, and "Replay haptic
  tutorial". The House picker at the top of settings switches demo houses and
  starts the new house's guided tour.

The first launch plays the haptic tutorial, then starts the guided tour. You
walk the tour yourself. It says where the next stop is and how many steps away,
and plays that room's description when you get there. Stopping and starting
the tour again puts you back at the front door. Once the tour has been
finished, later launches go straight to free exploring; the guided tour button
still starts it.

## Laptop viewer

The phone runs a small web server so a laptop can watch the avatar on the map
while the phone stays blank. The path is drawn on it as a dashed blue line with
a dot at every corner and a bigger one at every narrated stop, visible from the
moment the page loads, so you can see where the route goes before anyone walks
it. The header says whether the avatar is on the path or off it. Put the laptop and phone on the same network (the
phone's Personal Hotspot works when campus Wi-Fi blocks device-to-device
traffic), open the gear in the app, and open the address shown at the bottom
in a browser. It's `http://<phone IP>:8080`. Turn off "Laptop viewer" in
settings to stop the server.

## Re-tracing the floor plan

`tools/trace_floorplan.py` downloads the listing's floor plan images, finds the
walls, and writes `HouseTour/HouseTour/house.json`. Rooms, windows, and the tour
path are placed by hand in that file. It also checks that the tour path never
goes through a wall, and writes `tools/out/floor*_check.png` for a visual check.

The tour narration in `house.json` was reworded by hand so it no longer says
left or right (the app gives directions from your heading instead). `TOUR` in
the script still has the old wording, so copy the new lines into it before
re-tracing, or the old ones come back.

```sh
python3 -m venv .venv && .venv/bin/pip install numpy pillow scipy
.venv/bin/python tools/trace_floorplan.py
```

The Waterville house comes from `tools/plans/waterville.png` through
`tools/trace_waterville.py`, which reuses the same tracer and writes
`HouseTour/HouseTour/waterville.json` plus `tools/out/waterville/*_check.png`.
Its rooms, doors, and tour are in that script. The plan doesn't list floor
types, so every room except the garage is "Floor type not listed".

```sh
.venv/bin/python tools/trace_waterville.py
```

## Head-motion verification

Open `HouseTour/HouseTour.xcodeproj` in full Xcode and run on a physical iPhone.
Connect AirPods Pro and allow Motion access. Check that looking left/right
rotates the map arrow in the same direction, including across the yaw wrap;
calibrate while looking straight ahead and confirm returning to that pose
points the arrow straight up, including after restarting the tour or rejoining
the route;
horizontal drags do nothing; forward/backward drags retain the heading; the
fixed route still follows corners; and disconnect/reconnect resumes tracking
without a sudden turn. Backgrounding pauses motion updates.

Test a slow and fast approach to a wall, restarting the tour or changing
houses near a wall, retreat
past 1.25 feet and reentry. Confirm one short beep per approach and that speech
and effects reach the AirPods, with VoiceOver both enabled and disabled. Check
Motion permission denied and unsupported headphones for the spoken status.

## Live Mac AirPods demonstration

Run the Debug build on the HouseTour Review simulator. In the app's Settings,
turn on **Show map** and **Laptop viewer**. Open `http://127.0.0.1:8080` on
this Mac to see the dashed tour route and live avatar.

Connect and wear AirPods Pro, select them as the Mac's audio output, then run
`bash tests/build-airpods-probe.sh`. Open `/tmp/HouseTourAirPodsProbe.app` and
allow Motion access. The native Mac probe uses the app's actual HeadMotion
controller and forwards the absolute direction relative to calibrated forward
to the simulator. Look straight ahead and click **Calibrate forward** in the
probe, or use the same control in the simulator's Settings. Both controls
recenter the actual Mac sensor reference and mobile arrow together. Its warning button
plays the iPhone app's warning when the bridge is reachable; otherwise it plays
the same synthesized warning locally. Close the probe window to stop tracking.

The bridge listens only on `127.0.0.1:8081` and is compiled only for Debug
Simulator builds. It is absent from iPhone and Release builds. On a real iPhone,
connect AirPods directly to that iPhone; no Mac probe or bridge is used.

Vertical drags walk along the path. Horizontal drags do nothing. Double tap
leaves the path or rejoins it. Head motion changes the arrow and audio listener
heading without translating the avatar.
