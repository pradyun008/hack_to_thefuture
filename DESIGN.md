# House Tour: what you feel and what you hear

A blind home buyer explores a real listing (2011 O'Donnell Dr, Champaign) on an
iPhone. The screen works like a laptop trackpad. An avatar stands in the house,
starting just inside the front door, and dragging a finger moves it by the
finger's movement (0.09 ft per point, so a full-width swipe is about 35 ft).
Lifting and touching again never moves it, so nobody can aim at a door they
can see. Walls, windows, screens, and railings stop the avatar, and pushing
diagonally into a wall slides along it.

The avatar faces the way it last walked, and the trackpad turns with it:
finger up walks ahead, finger right walks to your right, finger down backs up.
The heading holds still while the finger is down, so a sideways drag can't
spin you in circles. On lift it turns to the way that drag walked (taken over
the last 1.5 ft of travel, so jitter can't flip it), unless you backed up,
which keeps your heading. It starts facing into the house, away from the
front door. Every spoken direction ("ahead", "on your left", "behind you on
your right") is relative to that heading, and the front door beacon turns
with it, so "on your left" always means drag left, never the left of the map.

The map is hidden. The touch surface is plain and dark with a one-line hint.
"Show map" in settings draws the plan and the avatar (a dot with a pointed head
showing its heading) for sighted people watching. Movement works the same either way.

The rule for splitting the channels: **anything the avatar touches is haptic,
anything about direction or distance is audio, and words are for names.**
Bluetooth audio lags about 200 ms, so nothing time-critical goes through the
earphones.

## Settings

Every channel has a switch. Defaults are calm, because testers found
everything-on overwhelming.

| Switch | Default |
|---|---|
| Wall approach hum | Off |
| Front door chime while touching | Off (triple tap plays it for 6 s anyway) |
| Floor texture vibration | On |
| Wind sound outside | Off |
| Speak room names | On |
| Speak doors when you reach them | On |
| Speak windows, railings, and fixtures | Off |
| Fine movement (a third of the normal gain) | Off |
| Show map | Off |

## Vibration (iPhone, Core Haptics)

| Event | Pattern | When |
|---|---|---|
| Wall | One hard, crisp knock. The only full-strength, full-sharpness single hit | On contact, then again every 0.3 s while you keep dragging into it. Sliding along a wall at a shallow angle doesn't repeat. The name (for non-walls) is said once per contact: a new contact needs 0.5 ft clear or 0.6 s without pushing. A corner is a new contact |
| Window | Glassy double ping | Same as a wall |
| Porch screen | Light knock with a short fizz | Same as a wall |
| Railing or open drop | Dull heavy thud | Same as a wall |
| Doorway | Two quick light taps | Within 1 ft of the door's opening. Again only after moving 2 ft away |
| Open-plan boundary | One soft tap | Kitchen to dining area, for example |
| Front door | Tap, tap, pause, tap | Plus a chime |
| Floor texture | One soft pattern per 2.5 ft footstep, at half strength or less | Carpet: smooth swell, no hits. Concrete: flat gritty scrape. Tile: two soft smooth pulses, spaced. Hardwood: three light, dull ticks, fading. Deck: a hollow drone, then a dull knock. Unknown floor: nothing |
| Built-in fixture | Soft dull bump | Only the fireplace is drawn on this plan |
| Stairs | Ladder of taps, rising going up, falling going down | Hold still on the stairs, finger down, for 1.2 s to change floors |
| Wall approach hum | Continuous, rises from 1.5 ft away | Only if switched on |

Floor textures differ by rhythm and count, not just sharpness, and each is under
200 ms. They stay at or below half intensity and use soft, low-sharpness hits or
smooth pulses, because testers felt crisp tile and hardwood taps as the same thing
as the wall knock. They play per footstep, not continuously, because constant vibration
numbs the hand. There is no footstep sound; floors are felt only.

## Sound (any headphones; AirPods optional)

| Sound | What it tells you | When |
|---|---|---|
| Front door beacon | Direction and distance to the entrance | Two-note chime every 1.5 s, placed in 3D at the door. While touching if switched on. Triple tap plays it louder for 6 s either way |
| Front door chime | You're at the front door | Once per arrival |
| Wind | You've left the house | Only if switched on |

### Spoken (VoiceOver if it's on, otherwise the built-in voice)

Speech only happens when something changes or when the user asks. Taps and
buttons never interrupt or queue speech: if anything is being said, the request
is skipped. Tour narration can't be cut off by anything except stopping or
moving the tour; floor changes and stair hints wait behind it, and room, door, obstacle,
and fixture names are dropped while it plays, since they'd be stale by the end.

| When | Says | Example |
|---|---|---|
| Entering a room | Name, size, floor | "Kitchen. 14 by 13 feet. Tile." |
| Standing in a door | Where it goes | "Door to Kitchen." "Opening to Dining area." "Front door." |
| Single tap | The room | "Living room." |
| Double tap | Room and floor, nearest doors and where they go, nearest built-in or the stairs, the front door | "Kitchen, first floor. The opening to Dining area is on your right, about 2 steps. The stairs are behind you on your left, about 6 steps. The front door is behind you, about 7 steps." |
| Two-finger tap | Floor, room, nearest wall, floor type, way to the front door | "First floor, Kitchen. Near the wall on your left. Tile. The front door is behind you on your right, about 7 steps." |
| Triple tap | Way to the front door | "The front door is behind you, about 5 steps. Follow the chime." |
| Stairs | Direction and how to use them | "Stairs going up. Hold still to climb." |
| Guided tour | The next stop and how to get there | "Next stop, Kitchen. Go through the door to Kitchen, ahead on your right, about 3 steps." |

Outside the guided tour and the double tap, nothing gives directions to
interior doors. You learn a door is there by reaching it. A room is announced only after the avatar has been in it for
0.35 s or moved 1 ft past the boundary, so wiggling across a doorway doesn't
chatter.

## Modes

1. **Haptic tutorial** (runs on first launch, about a minute). Explains the
   trackpad, then plays each pattern with its name. It only teaches channels
   that are switched on.
2. **Guided tour** (starts after the tutorial on first launch). You walk it
   yourself, and can go anywhere. The hand-written path from the front door
   through every first-floor room, up the stairs, and into the primary suite
   and a bedroom is split into stops, one per narrated room. The app says where
   the next stop is, by heading and steps, and plays a room's description only
   when you reach it (within 2.5 ft, or once you're settled in its room; the
   stairs stop counts when you step onto the stairs). Then it points to the
   next stop. Walking for 10 s without getting closer repeats the directions,
   and a single tap asks for them. To change floors you hold still on the
   stairs as usual. "Previous room" aims back one stop, "Restart tour" returns
   to the front door, and "Jump to room" moves you to any stop and plays it.
   Finishing the tour is remembered, so later launches start in free explore.
3. **Free explore.** Drag to walk. "Fine movement" makes each swipe go a third
   as far, for lining up with a narrow doorway.

## Where the data comes from

| Data | Source |
|---|---|
| Walls, rooms, doors, windows, stairs, room sizes | The listing's two CubiCasa floor plan images, traced by `tools/trace_floorplan.py` |
| Floor types | The listing photos. Laundry, half bath, and the small room aren't shown, so they're "not listed" instead of guessed |
| Formal dining room label | The plan says "Room"; the listing description mentions a separate formal dining room |
| Fixtures | Only what the plan draws: stairs, fireplace, the open-to-below railing. Kitchen counters and bathroom fixtures aren't on the plan, so they're left out |

## Known limits

- The phone vibrates as one unit, so left and right come only from audio.
- The "Go upstairs" button puts you on the stairs. Climbing by holding still
  keeps your spot.
- No phone-rotation or AirPods head tracking yet. Ahead is the avatar's
  walking direction, not the way the user's head or phone points.
