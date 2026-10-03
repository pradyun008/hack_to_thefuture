#!/usr/bin/env python3
"""Trace the listing floor plans for 2011 O'Donnell Dr into HouseTour/house.json.

Walls come from the plan images (thick black pixels). Rooms, windows, fixtures,
and the guided tour are hand-placed in image pixel coordinates below, then
everything is converted to feet. Doorways are found automatically: any place
two rooms touch without a wall between them.

Run:  python3 tools/trace_floorplan.py        (needs numpy, pillow, scipy)
Writes HouseTour/HouseTour/house.json and tools/out/*_check.png for eyeballing.
"""
import json
import os
import urllib.request
from collections import deque

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC_DIR = os.path.join(HERE, "source")
OUT_DIR = os.path.join(HERE, "out")
JSON_OUT = os.path.join(REPO, "HouseTour", "HouseTour", "house.json")

LISTING = "https://www.zillow.com/homedetails/2011-O'Donnell-Dr-Champaign-IL-61821/3232829_zpid/"
PHOTO_URL = "https://photos.zillowstatic.com/fp/{}-uncropped_scaled_within_1536_1152.png"

CELL = 0.25          # feet per grid cell
WIDTH, HEIGHT = 61.0, 53.0
# Where the outer top-left corner of the main block (living room / bedroom 2 corner)
# sits in the house frame. Leaves room for the porch above it.
ORIGIN_FT = (1.0, 15.5)

# image id, pixels per foot (measured from labelled room sizes), pixel of the
# main block's outer top-left corner. Both floors share that corner (checked on
# the side-by-side plan: stairs line up at the same offset).
PLANS = {
    0: ("8e7170051baa67924a38abf2873b1041", 16.15, (240, 268)),
    1: ("2e0b767aff6ee5f1a1103b9245da4e3b", 24.45, (248, 32)),
}

# Cell codes. Anything other than OPEN blocks the "walker".
OPEN, WALL, WINDOW, SCREEN, RAILING, VOID = ".", "#", "w", "s", "r", "v"

# ---------------------------------------------------------------------------
# Hand-placed features, in pixel coordinates of each floor's plan image.
# Rects are (x0, y0, x1, y1). Floor types come from the listing photos.
# ---------------------------------------------------------------------------
ROOMS = {
    0: [
        dict(name="Formal dining room", floor="carpet", size=(13.5, 12.9), rects=[(247, 276, 465, 487)],
             note="Labelled 'Room' on the plan. The listing describes a separate formal dining room."),
        dict(name="Living room", floor="carpet", size=(13.5, 19.3), rects=[(247, 491, 465, 803)]),
        dict(name="Foyer", floor="hardwood", size=(14.0, 13.75),
             rects=[(470, 598, 697, 708), (636, 491, 697, 598), (470, 530, 575, 598)]),
        dict(name="Storage nook", floor="unknown", size=None, rects=[(470, 491, 575, 528)], kind="closet"),
        dict(name="Foyer closet", floor="unknown", size=None, rects=[(580, 491, 632, 596)], kind="closet"),
        dict(name="Kitchen", floor="tile", size=(14.0, 12.9), rects=[(470, 276, 697, 485)]),
        dict(name="Dining area", floor="tile", size=(7.7, 10.8), rects=[(697, 276, 820, 450)]),
        dict(name="Family room", floor="carpet", size=(23.1, 13.75), rects=[(820, 228, 1193, 450)]),
        dict(name="Half bath", floor="unknown", size=(4.3, 5.9), rects=[(702, 457, 772, 551)], kind="bath"),
        dict(name="Small room", floor="unknown", size=(4.75, 5.9), rects=[(777, 457, 851, 551)],
             note="Unlabelled 4 by 6 foot room on the plan."),
        dict(name="Laundry room", floor="unknown", size=(9.3, 9.25), rects=[(702, 557, 851, 708)]),
        dict(name="Garage", floor="concrete", size=(20.6, 24.0), rects=[(860, 460, 1193, 848)]),
        dict(name="Screened porch", floor="deck", size=(17.0, 11.25), rects=[(866, 80, 1131, 222), (895, 45, 1108, 80)]),
        dict(name="Stairs", floor="carpet", size=None, rects=[(470, 530, 575, 628)], kind="stairs"),
    ],
    1: [
        dict(name="Bedroom 2", floor="carpet", size=(11.4, 12.5), rects=[(260, 44, 540, 350)]),
        dict(name="Primary bedroom", floor="carpet", size=(16.1, 12.6), rects=[(549, 44, 942, 350)]),
        dict(name="Primary bath", floor="tile", size=(9.3, 4.6), rects=[(952, 187, 1180, 302)], kind="bath"),
        dict(name="Hall bath", floor="tile", size=(9.3, 5.1), rects=[(952, 312, 1180, 435)], kind="bath"),
        dict(name="Upstairs hall", floor="carpet", size=(19.6, 6.75),
             rects=[(465, 357, 944, 426), (850, 426, 944, 525)]),
        dict(name="Bedroom 3", floor="carpet", size=(13.5, 16.7),
             rects=[(260, 500, 590, 845), (522, 435, 590, 500)]),
        dict(name="Bedroom 4", floor="carpet", size=(10.3, 10.3),
             rects=[(927, 532, 1180, 700), (950, 445, 1180, 532)]),
        dict(name="Bedroom 2 closet", floor="carpet", size=None, rects=[(260, 357, 455, 428)], kind="closet"),
        dict(name="Bedroom 3 closet", floor="carpet", size=None, rects=[(260, 436, 455, 492)], kind="closet"),
        dict(name="Linen closet", floor="carpet", size=None, rects=[(463, 436, 513, 492)], kind="closet"),
        dict(name="Bedroom 4 closet", floor="carpet", size=None, rects=[(892, 532, 920, 695)], kind="closet"),
        dict(name="Stairs", floor="carpet", size=None, rects=[(600, 436, 842, 525), (600, 525, 680, 577)],
             kind="stairs"),
    ],
}

WINDOWS = {
    0: [(290, 267, 401, 277), (544, 267, 596, 276), (718, 267, 804, 276), (737, 704, 790, 716),
        (304, 800, 412, 812)],
    1: [(353, 32, 437, 46), (581, 32, 652, 43), (829, 32, 913, 45), (943, 79, 956, 145),
        (247, 265, 256, 348), (247, 533, 260, 629), (977, 693, 1081, 709), (359, 842, 524, 855),
        (604, 734, 879, 741)],
}
SCREEN_RECTS = {0: [(905, 30, 1096, 40), (852, 80, 864, 217), (1133, 80, 1145, 216)]}
SCREEN_LINES = {0: [((857, 75), (897, 35)), ((1104, 35), (1140, 71))]}
RAILINGS = {1: [(599, 426, 850, 436)]}
VOIDS = {1: [(682, 533, 882, 732), (600, 579, 682, 732)]}
FIXTURES = {0: [dict(name="Fireplace", rect=(1143, 276, 1193, 400))]}

# Exterior doors, matched to auto-detected exterior openings by distance.
EXTERIOR_DOORS = {
    0: [dict(name="Front door", at=(585, 712), front=True),
        dict(name="Garage door", at=(1028, 848)),
        dict(name="Garage side door", at=(1197, 590))],
}

# Guided tour: (floor, x, y, narration). Narration is spoken when the walker
# reaches that point; the walk waits for it to finish. "climb" switches floors.
# Directions use the app's fixed frame: top of the screen is ahead, the street
# side is behind. Not the walker's heading.
TOUR = [
    (0, 585, 695, "Starting just inside the front door, in the foyer. Hardwood parquet floor. "
                  "The foyer is about 14 by 14 feet. The stairs are ahead on your left."),
    (0, 585, 662, None),
    (0, 500, 665, "The living room doorway is on your left."),
    (0, 440, 665, None),
    (0, 356, 650, "Living room. About 14 by 19 feet, carpet. The windows face the street, behind you. "
                  "A wide opening ahead leads to the formal dining room."),
    (0, 350, 560, None),
    (0, 350, 440, None),
    (0, 356, 380, "Formal dining room. About 14 by 13 feet, carpet. Windows on the back wall ahead. "
                  "A doorway on your right leads to the kitchen."),
    (0, 420, 430, None),
    (0, 510, 430, None),
    (0, 585, 380, "Kitchen. About 14 by 13 feet, tile. The listing says the appliances, counters, "
                  "and backsplash are new. The kitchen flows straight into the dining area on your right."),
    (0, 760, 360, "Dining area, tile. There's no wall here. It opens into the family room on your right."),
    (0, 900, 340, None),
    (0, 1000, 340, "Family room. About 23 by 14 feet, carpet, with a fireplace on the right wall. "
                   "The door to the screened porch is ahead."),
    (0, 990, 260, None),
    (0, 990, 180, None),
    (0, 998, 120, "Screened porch. About 17 by 11 feet, with a deck floor and screens on three sides."),
    (0, 990, 280, None),
    (0, 760, 420, None),
    (0, 665, 430, None),
    (0, 665, 500, "Back through the kitchen, into the back of the foyer. The half bath is on your right."),
    (0, 665, 652, "The laundry room is on your right."),
    (0, 720, 652, None),
    (0, 778, 645, "Laundry room, about 9 by 9 feet. A door on your right leads to the garage."),
    (0, 880, 652, None),
    (0, 1000, 652, "Garage. An oversized two car garage, about 21 by 24 feet, concrete. "
                   "The big garage door is behind you."),
    (0, 880, 652, None),
    (0, 680, 652, None),
    (0, 600, 650, None),
    (0, 495, 645, "Stairs to the second floor. Carpeted, with a turn partway up."),
    (0, 495, 600, "climb"),
    (1, 640, 550, None),
    (1, 760, 480, None),
    (1, 895, 480, "Top of the stairs. Upstairs hall, carpet. The hall bath is ahead on your right, "
                  "and the primary bedroom door is straight ahead."),
    (1, 895, 400, None),
    (1, 900, 330, None),
    (1, 800, 200, "Primary bedroom. About 16 by 13 feet, carpet. Its own bathroom is through the door "
                  "on your right."),
    (1, 900, 230, None),
    (1, 1010, 235, "Primary bath, tile."),
    (1, 900, 230, None),
    (1, 900, 330, None),
    (1, 880, 390, None),
    (1, 555, 390, None),
    (1, 555, 470, None),
    (1, 520, 560, None),
    (1, 430, 650, "Bedroom 3. About 14 by 17 feet, carpet, at the front corner of the house. "
                  "That's the end of the tour. Explore on your own. Two finger tap asks where you are, "
                  "and a triple tap points you to the front door."),
]


def fetch(image_id):
    os.makedirs(SRC_DIR, exist_ok=True)
    path = os.path.join(SRC_DIR, image_id + ".png")
    if not os.path.exists(path):
        req = urllib.request.Request(PHOTO_URL.format(image_id), headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req) as r, open(path, "wb") as f:
            f.write(r.read())
    return path


class Plan:
    def __init__(self, floor):
        image_id, self.ppf, self.corner = PLANS[floor]
        self.gray = np.array(Image.open(fetch(image_id)).convert("L")).astype(int)
        self.gray[930:, :] = 255  # footer text

    def to_ft(self, px, py):
        return ((px - self.corner[0]) / self.ppf + ORIGIN_FT[0],
                (py - self.corner[1]) / self.ppf + ORIGIN_FT[1])

    def to_px(self, fx, fy):
        return ((fx - ORIGIN_FT[0]) * self.ppf + self.corner[0],
                (fy - ORIGIN_FT[1]) * self.ppf + self.corner[1])

    def rect_ft(self, r):
        x0, y0 = self.to_ft(r[0], r[1])
        x1, y1 = self.to_ft(r[2], r[3])
        return [round(x0, 2), round(y0, 2), round(x1 - x0, 2), round(y1 - y0, 2)]


def wall_mask(g):
    thick = ndi.binary_opening(g < 70, structure=np.ones((6, 6)))
    thin = ndi.binary_opening(g < 150, structure=np.ones((3, 3)))
    lab, n = ndi.label(thin)
    sizes = ndi.sum(thin, lab, range(1, n + 1))
    thin = np.isin(lab, [i + 1 for i, s in enumerate(sizes) if s > 80])
    return thick | thin


def build_floor(floor):
    plan = Plan(floor)
    h, w = plan.gray.shape
    # Pixel-level code image, later pooled into cells. Higher priority wins.
    priority = {OPEN: 0, VOID: 1, WALL: 2, RAILING: 3, SCREEN: 4, WINDOW: 5}
    code_img = np.zeros((h, w), dtype=np.uint8)
    code_img[wall_mask(plan.gray)] = priority[WALL]
    pil = Image.fromarray(np.zeros((h, w), dtype=np.uint8))
    d = ImageDraw.Draw(pil)
    for r in VOIDS.get(floor, []):
        d.rectangle(r, fill=priority[VOID])
    void_layer = np.array(pil)
    code_img = np.where((void_layer > 0) & (code_img == 0), void_layer, code_img)
    pil = Image.fromarray(code_img)
    d = ImageDraw.Draw(pil)
    for r in RAILINGS.get(floor, []):
        d.rectangle(r, fill=priority[RAILING])
    for r in SCREEN_RECTS.get(floor, []):
        d.rectangle(r, fill=priority[SCREEN])
    for a, b in SCREEN_LINES.get(floor, []):
        d.line([a, b], fill=priority[SCREEN], width=7)
    for r in WINDOWS.get(floor, []):
        d.rectangle(r, fill=priority[WINDOW])
    code_img = np.array(pil)

    cols, rows = int(WIDTH / CELL), int(HEIGHT / CELL)
    inv = {v: k for k, v in priority.items()}
    cells = np.full((rows, cols), OPEN, dtype="<U1")
    half = CELL / 2
    for r in range(rows):
        for c in range(cols):
            x0, y0 = plan.to_px(c * CELL, r * CELL)
            x1, y1 = plan.to_px(c * CELL + CELL, r * CELL + CELL)
            xa, xb = max(int(x0), 0), min(int(np.ceil(x1)), w)
            ya, yb = max(int(y0), 0), min(int(np.ceil(y1)), h)
            if xa >= xb or ya >= yb:
                continue
            block = code_img[ya:yb, xa:xb]
            m = int(block.max())
            if m == priority[VOID]:
                # Void only if most of the cell is void, so the railing edge is crisp.
                m = priority[VOID] if (block == priority[VOID]).mean() > 0.5 else 0
            cells[r, c] = inv[m]
    _ = half

    # Room labels: rect membership first, then let rooms grow a little into
    # doorway gaps (walls are ~0.5 ft thick, so gaps are 2 to 3 cells).
    rooms = ROOMS[floor]
    label = np.full((rows, cols), -1, dtype=int)
    for i, room in enumerate(rooms):
        for rect in room["rects"]:
            fx, fy, fw, fh = plan.rect_ft(rect)
            c0, r0 = int(round(fx / CELL)), int(round(fy / CELL))
            c1, r1 = int(round((fx + fw) / CELL)), int(round((fy + fh) / CELL))
            label[r0:r1, c0:c1] = i
    blocked = cells != OPEN
    label[blocked] = -1
    grow(label, blocked, depth=3)

    # Unlabelled open cells not reachable from the map edge are pockets inside
    # the house that the rects missed. Give them to the nearest room.
    outside = (label == -1) & ~blocked
    lab, n = ndi.label(outside)
    edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
    pockets = outside & ~np.isin(lab, list(edge))
    if pockets.any():
        print(f"floor {floor}: filling {pockets.sum()} pocket cells")
        grow(label, blocked, depth=40, only=pockets)

    doors = find_doors(label, blocked, rooms, floor, plan)
    fixtures = [dict(name=f["name"], rect=plan.rect_ft(f["rect"])) for f in FIXTURES.get(floor, [])]

    room_out = []
    for i, room in enumerate(rooms):
        ys, xs = np.nonzero(label == i)
        bounds = [round(xs.min() * CELL, 2), round(ys.min() * CELL, 2),
                  round((xs.max() - xs.min() + 1) * CELL, 2), round((ys.max() - ys.min() + 1) * CELL, 2)]
        out = dict(name=room["name"], floor=room["floor"], kind=room.get("kind", "room"), bounds=bounds)
        if room.get("size"):
            out["size"] = list(room["size"])
        if room.get("note"):
            out["note"] = room["note"]
        room_out.append(out)

    label_chars = np.where(label >= 0, np.vectorize(lambda v: chr(65 + v))(np.maximum(label, 0)), ".")
    data = dict(
        name="First floor" if floor == 0 else "Second floor",
        cols=cols, rows=rows,
        cells="".join("".join(row) for row in cells),
        rooms="".join("".join(row) for row in label_chars),
        roomList=room_out, doors=doors, fixtures=fixtures,
    )
    render_check(floor, plan, cells, label, doors)
    return data, plan, cells


def grow(label, blocked, depth, only=None):
    q = deque()
    dist = np.full(label.shape, -1, dtype=int)
    for r, c in zip(*np.nonzero(label >= 0)):
        q.append((r, c))
        dist[r, c] = 0
    rows, cols = label.shape
    while q:
        r, c = q.popleft()
        if dist[r, c] >= depth:
            continue
        for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            rr, cc = r + dr, c + dc
            if 0 <= rr < rows and 0 <= cc < cols and label[rr, cc] == -1 and not blocked[rr, cc]:
                if only is not None and not only[rr, cc]:
                    continue
                label[rr, cc] = label[r, c]
                dist[rr, cc] = dist[r, c] + 1
                q.append((rr, cc))


def find_doors(label, blocked, rooms, floor, plan):
    rows, cols = label.shape
    pairs = {}
    for r in range(rows):
        for c in range(cols):
            if blocked[r, c]:
                continue
            for dr, dc in ((1, 0), (0, 1)):
                rr, cc = r + dr, c + dc
                if rr >= rows or cc >= cols or blocked[rr, cc]:
                    continue
                a, b = label[r, c], label[rr, cc]
                if a != b:
                    key = (min(a, b), max(a, b))
                    pairs.setdefault(key, set()).update({(r, c), (rr, cc)})
    doors = []
    ext_named = EXTERIOR_DOORS.get(floor, [])
    for (a, b), cellset in sorted(pairs.items()):
        m = np.zeros(label.shape, dtype=bool)
        for rc in cellset:
            m[rc] = True
        lab, n = ndi.label(m, structure=np.ones((3, 3)))
        for k in range(1, n + 1):
            ys, xs = np.nonzero(lab == k)
            if len(ys) < 3:
                continue
            if max(xs.max() - xs.min() + 1, ys.max() - ys.min() + 1) * CELL < 1.0:
                continue  # sliver where a door straddles two open-plan rooms
            cx, cy = (xs.mean() + 0.5) * CELL, (ys.mean() + 0.5) * CELL
            width = max(xs.max() - xs.min() + 1, ys.max() - ys.min() + 1) * CELL
            door = dict(x=round(cx, 2), y=round(cy, 2), width=round(width, 2))
            if a == -1:
                door.update(a=int(b), b=-1, kind="exterior")
                best = min(ext_named, key=lambda e: dist2(plan.to_ft(*e["at"]), (cx, cy)), default=None)
                if best and dist2(plan.to_ft(*best["at"]), (cx, cy)) < 6 ** 2:
                    door["name"] = best["name"]
                    if best.get("front"):
                        door["front"] = True
                else:
                    print(f"  WARNING floor {floor}: unnamed exterior opening at ({cx:.1f},{cy:.1f}) "
                          f"from {rooms[b]['name']}, width {width:.1f}")
                    continue
            else:
                door.update(a=int(a), b=int(b), kind="opening" if width > 6.5 else "doorway")
            doors.append(door)
            other = "outside" if door["b"] == -1 else rooms[door["b"]]["name"]
            print(f"  floor {floor}: {door['kind']:8s} {rooms[door['a']]['name']} <-> {other} "
                  f"at ({cx:.1f},{cy:.1f}) width {width:.1f}")
    return doors


def dist2(p, q):
    return (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2


def render_check(floor, plan, cells, label, doors):
    os.makedirs(OUT_DIR, exist_ok=True)
    s = 8
    rows, cols = cells.shape
    img = Image.new("RGB", (cols * s, rows * s), "white")
    d = ImageDraw.Draw(img)
    palette = [(255, 224, 178), (200, 230, 201), (187, 222, 251), (225, 190, 231), (255, 249, 196),
               (178, 235, 242), (248, 187, 208), (220, 237, 200), (209, 196, 233), (255, 204, 188)]
    colors = {WALL: (0, 0, 0), WINDOW: (30, 90, 255), SCREEN: (0, 160, 160), RAILING: (255, 120, 0),
              VOID: (150, 150, 150)}
    for r in range(rows):
        for c in range(cols):
            k = cells[r, c]
            col = colors.get(k) or (palette[label[r, c] % len(palette)] if label[r, c] >= 0 else (255, 255, 255))
            d.rectangle([c * s, r * s, c * s + s - 1, r * s + s - 1], fill=col)
    for door in doors:
        x, y = door["x"] / CELL * s, door["y"] / CELL * s
        col = {"doorway": "red", "opening": "magenta", "exterior": "green"}[door["kind"]]
        d.ellipse([x - 8, y - 8, x + 8, y + 8], outline=col, width=3)
    for i, room in enumerate(ROOMS[floor]):
        ys, xs = np.nonzero(label == i)
        if len(xs):
            d.text((xs.mean() * s - 30, ys.mean() * s), room["name"], fill="black")
    img.save(os.path.join(OUT_DIR, f"floor{floor + 1}_check.png"))


def check_tour(floor_data):
    """Walk the tour path on the grid and fail loudly if it clips a wall."""
    tour = []
    prev = None
    for floor, px, py, say in TOUR:
        plan = Plan.__new__(Plan)
        _, plan.ppf, plan.corner = PLANS[floor]
        x, y = plan.to_ft(px, py)
        step = dict(floor=floor, x=round(x, 2), y=round(y, 2))
        if say == "climb":
            step["climb"] = True
        elif say:
            step["say"] = say
        if prev and prev["floor"] == floor:
            cells = floor_data[floor]
            n = int(max(abs(x - prev["x"]), abs(y - prev["y"])) / 0.05) + 1
            for i in range(n + 1):
                t = i / n
                cx = prev["x"] + (x - prev["x"]) * t
                cy = prev["y"] + (y - prev["y"]) * t
                k = cells[int(cy / CELL), int(cx / CELL)]
                if k != OPEN:
                    raise SystemExit(f"tour segment {prev} -> {step} hits '{k}' at ({cx:.1f},{cy:.1f})")
        tour.append(step)
        prev = step
    return tour


def main():
    floors, grids = [], {}
    front = None
    for floor in (0, 1):
        print(f"floor {floor + 1}")
        data, plan, cells = build_floor(floor)
        floors.append(data)
        grids[floor] = cells
        for e in EXTERIOR_DOORS.get(floor, []):
            if e.get("front"):
                fx, fy = plan.to_ft(*e["at"])
                front = dict(floor=floor, x=round(fx, 2), y=round(fy, 2))
    house = dict(
        address="2011 O'Donnell Dr, Champaign, IL 61821",
        source=LISTING,
        summary="4 bedrooms, 2.5 baths, 2,487 square feet, built 1985.",
        cellSize=CELL, width=WIDTH, height=HEIGHT,
        frontDoor=front, floors=floors, tour=check_tour(grids),
    )
    os.makedirs(os.path.dirname(JSON_OUT), exist_ok=True)
    with open(JSON_OUT, "w") as f:
        json.dump(house, f, separators=(",", ":"))
    print(f"wrote {JSON_OUT} ({os.path.getsize(JSON_OUT) // 1024} KB)")


if __name__ == "__main__":
    main()
