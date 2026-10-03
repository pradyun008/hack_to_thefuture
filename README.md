# hack_to_thefuture

House Tour: an iPhone app that lets a blind home buyer explore a real listing's
floor plan by touch, with haptics for what the avatar walks over and spatial audio
for direction. Demo house is 2011 O'Donnell Dr, Champaign, IL. See
[DESIGN.md](DESIGN.md) for the haptic and audio vocabulary.

## Run it on an iPhone

Haptics only work on a real device.

1. Plug the iPhone in with a cable, unlock it, and tap Trust if asked. Developer
   Mode must be on (Settings > Privacy & Security > Developer Mode).
2. Open `HouseTour/HouseTour.xcodeproj` in Xcode, pick the phone as the run
   destination, and press Run. Signing uses team `9XPPP9TMHQ`; change
   `DEVELOPMENT_TEAM` in `HouseTour/project.yml` for another account and run
   `xcodegen generate` in `HouseTour/`.
3. First launch plays the haptic tutorial. Plug in headphones to hear the
   front door chime in 3D.

From the command line instead:

```sh
cd HouseTour
xcodebuild -project HouseTour.xcodeproj -scheme HouseTour -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device id from `xcrun devicectl list devices`> \
  build/Build/Products/Debug-iphoneos/HouseTour.app
```

## Controls

The screen is a trackpad, and the map is hidden. Your avatar starts just inside
the front door.

- Drag one finger: walk. The avatar moves by how far the finger moves, not to
  where it is. Lifting and touching again never moves you. Walls stop you.
- Single tap: which room you're in.
- Two-finger tap: where am I.
- Triple tap: find the front door.
- Hold still on the stairs, finger down, for about a second: change floors.
- Buttons: guided tour, where am I, go up or downstairs, fine movement, find
  front door, haptic tutorial. The gear opens settings, with a switch for each
  sound, vibration, and spoken cue, plus "Show map" for people watching.

## Laptop viewer

The phone runs a small web server so a laptop can watch the avatar on the map
while the phone stays blank. Put the laptop and phone on the same network (the
phone's Personal Hotspot works when campus Wi-Fi blocks device-to-device
traffic), open the gear in the app, and open the address shown at the bottom
in a browser. It's `http://<phone IP>:8080`. Turn off "Laptop viewer" in
settings to stop the server.

## Re-tracing the floor plan

`tools/trace_floorplan.py` downloads the listing's floor plan images, finds the
walls, and writes `HouseTour/HouseTour/house.json`. Rooms, windows, and the tour
path are placed by hand in that file. It also checks that the tour path never
goes through a wall, and writes `tools/out/floor*_check.png` for a visual check.

```sh
python3 -m venv .venv && .venv/bin/pip install numpy pillow scipy
.venv/bin/python tools/trace_floorplan.py
```
