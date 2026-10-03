# House Tour: what you feel and what you hear

A blind home buyer explores a real listing (2011 O'Donnell Dr, Champaign) on an
iPhone. The screen works like a laptop trackpad. An avatar stands in the house,
starting just inside the front door, and dragging a finger moves it by the
finger's movement (0.09 ft per point, so a full-width swipe is about 35 ft).
Lifting and touching again never moves it, so nobody can aim at a door they
can see. Walls, windows, screens, and railings stop the avatar, and pushing
diagonally into a wall slides along it. The top of the screen is always
"ahead".

The map is hidden. The touch surface is plain and dark with a one-line hint.
"Show map" in settings draws the plan and the avatar for sighted people
watching. Movement works the same either way.

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
| Wall | One hard, crisp knock | Once per contact. Pushing into the same wall stays quiet until you move 0.5 ft clear or stop pushing for 0.6 s. A corner is a new contact |
| Window | Glassy double ping | Same as a wall |
| Porch screen | Light knock with a short fizz | Same as a wall |
| Railing or open drop | Dull heavy thud | Same as a wall |
| Doorway | Two quick light taps | Within 1 ft of the door's opening. Again only after moving 2 ft away |
| Open-plan boundary | One soft tap | Kitchen to dining area, for example |
| Front door | Tap, tap, pause, tap | Plus a chime |
| Floor texture | One pattern per 2.5 ft footstep | Carpet: smooth swell, no hits. Concrete: one heavy thud. Tile: two taps, spaced. Hardwood: three fast ticks. Deck: long, then short. Unknown floor: nothing |
| Built-in fixture | Soft dull bump | Only the fireplace is drawn on this plan |
| Stairs | Ladder of taps, rising going up, falling going down | Hold still on the stairs, finger down, for 1.2 s to change floors |
| Wall approach hum | Continuous, rises from 1.5 ft away | Only if switched on. Off during the guided tour |

Floor textures differ by rhythm and count, not just sharpness, and each is under
200 ms. They play per footstep, not continuously, because constant vibration
numbs the hand. There is no footstep sound; floors are felt only.

## Sound (any headphones; AirPods optional)

| Sound | What it tells you | When |
|---|---|---|
| Front door beacon | Direction and distance to the entrance | Two-note chime every 1.5 s, placed in 3D at the door. While touching if switched on. Triple tap plays it louder for 6 s either way |
| Front door chime | You're at the front door | Once per arrival |
| Wind | You've left the house | Only if switched on |

### Spoken (VoiceOver if it's on, otherwise the built-in voice)

Speech only happens when something changes or when the user asks.

| When | Says | Example |
|---|---|---|
| Entering a room | Name, size, floor | "Kitchen. 14 by 13 feet. Tile." |
| Standing in a door | Where it goes | "Door to Kitchen." "Opening to Dining area." "Front door." |
| Single tap | The room | "Living room." |
| Two-finger tap | Floor, room, nearest wall, floor type, way to the front door | "First floor, Kitchen. Near the wall ahead. Tile. The front door is behind you on your right, about 7 steps." |
| Triple tap | Way to the front door | "The front door is behind you, about 5 steps. Follow the chime." |
| Stairs | Direction and how to use them | "Stairs going up. Hold still to climb." |

Nothing gives directions to interior doors. You learn a door is there by
reaching it. A room is announced only after the avatar has been in it for
0.35 s or moved 1 ft past the boundary, so wiggling across a doorway doesn't
chatter.

## Modes

1. **Haptic tutorial** (runs on first launch, about a minute). Explains the
   trackpad, then plays each pattern with its name. It only teaches channels
   that are switched on.
2. **Guided tour.** The app moves the avatar along a hand-written path at 3 ft/s
   from the front door through every first-floor room, up the stairs, and into
   the primary suite and a bedroom, narrating as it goes. Touching the screen
   stops it, and you keep exploring from where it stopped.
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
- No phone-rotation or AirPods head tracking yet. Ahead is always up.
