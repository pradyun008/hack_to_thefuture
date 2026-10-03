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
- On the path, only along-the-path movement counts: drag ahead to go onward,
  drag back to come back, and a sideways drag does nothing. The trackpad turns
  with the route, so "ahead" stays onward around a corner. The two ends of the
  route knock like walls.
- Off the path, directions are relative to the way you face, and so is the
  trackpad: drag up to go "ahead", drag left to go "on your left". On lift you
  turn to face the way you walked, unless you backed up.
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
