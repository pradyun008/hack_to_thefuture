#!/usr/bin/env python3
"""Trace the Waterville floor plan (tools/plans/waterville.png) into
HouseTour/HouseTour/waterville.json, the app's second demo house.

Reuses the wall finding, room growing, door detection, and tour check from
trace_floorplan.py by swapping in this plan's hand-placed features. Both levels
are in one image, upper on top. They share the same x, and the upper level sits
494 px higher: the stairs and the front wall of the open-to-below living room
line up at that offset.

Run:  .venv/bin/python tools/trace_waterville.py
Writes HouseTour/HouseTour/waterville.json and tools/out/waterville/*_check.png.
"""
import json
import os

import numpy as np
from PIL import Image

import trace_floorplan as tf

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE = os.path.join(HERE, "plans", "waterville.png")
JSON_OUT = os.path.join(tf.REPO, "HouseTour", "HouseTour", "waterville.json")

PPF = 14.7          # pixels per foot, from the labelled garage, foyer, and living room sizes
UPPER_SHIFT = 494   # px the upper level is drawn above its true spot
# Pixel of the fireplace bump's outer left edge and the back wall's top. It
# sits at (2, 2) ft so there's a little yard around the house.
CORNER = (21, 524)

# Hand-placed features, in pixels of waterville.png. Upper-level features use
# the upper drawing's own pixels; the shift is applied by its Plan.
# Floor types aren't on the plan, so everything but the garage is "unknown".
ROOMS = {
    0: [
        dict(name="Family room", floor="unknown", size=(15.67, 17.33), rects=[(58, 553, 291, 810)]),
        dict(name="Breakfast nook", floor="unknown", size=(11.5, 12.92), rects=[(297, 533, 457, 689)]),
        dict(name="Kitchen", floor="unknown", size=(9.42, 12.58), rects=[(457, 533, 598, 717)]),
        dict(name="Pantry", floor="unknown", size=None, rects=[(357, 696, 397, 726)], kind="closet"),
        dict(name="Laundry room", floor="unknown", size=(7.0, 7.75),
             rects=[(297, 696, 350, 732), (297, 732, 397, 810)]),
        dict(name="Closet under the stairs", floor="unknown", size=None, rects=[(463, 722, 510, 770)],
             kind="closet"),
        dict(name="Foyer", floor="unknown", size=(13.58, 9.58),
             rects=[(403, 773, 603, 915), (403, 689, 457, 773)]),
        dict(name="Half bath", floor="unknown", size=(4.17, 4.17), rects=[(403, 880, 470, 940)], kind="bath"),
        dict(name="Dining area", floor="unknown", size=(13.08, 10.75),
             rects=[(603, 555, 768, 713), (768, 575, 797, 671)]),
        dict(name="Living room", floor="unknown", size=(11.33, 13.83), rects=[(603, 713, 768, 915)],
             note="Open to the second floor above."),
        dict(name="Garage", floor="concrete", size=(22.83, 18.33), rects=[(59, 817, 395, 1085)]),
        dict(name="Garage closet", floor="concrete", size=None, rects=[(356, 817, 395, 895)], kind="closet"),
        dict(name="Stairs", floor="unknown", size=None, rects=[(545, 722, 598, 823), (510, 722, 545, 770)],
             kind="stairs"),
    ],
    1: [
        dict(name="Walk-in closet", floor="unknown", size=(6.67, 7.67), rects=[(58, 37, 157, 150)], kind="closet"),
        dict(name="Primary bath", floor="unknown", size=(11.25, 7.58), rects=[(162, 37, 325, 150)], kind="bath"),
        dict(name="Shower room", floor="unknown", size=(5.83, 4.92), rects=[(332, 37, 418, 100)], kind="bath",
             note="Shower and toilet, off the primary bath."),
        dict(name="Hall bath", floor="unknown", size=(8.0, 7.33),
             rects=[(332, 115, 370, 222), (300, 155, 332, 222), (370, 115, 418, 180)], kind="bath"),
        dict(name="Primary bedroom", floor="unknown", size=(16.0, 14.17), rects=[(58, 153, 297, 365)]),
        dict(name="Upstairs hall", floor="unknown", size=(9.92, 3.17), rects=[(302, 227, 443, 275)]),
        dict(name="Bedroom 2", floor="unknown", size=(18.25, 12.58),
             rects=[(423, 37, 607, 222), (380, 185, 423, 222), (607, 115, 645, 222)]),
        dict(name="Bedroom 2 closet", floor="unknown", size=None, rects=[(613, 40, 645, 115)], kind="closet"),
        dict(name="Attic", floor="unknown", size=(8.17, 12.58), rects=[(650, 37, 770, 222)]),
        dict(name="Bedroom 3", floor="unknown", size=(11.5, 11.25), rects=[(302, 287, 470, 447)]),
        dict(name="Bedroom 3 closet", floor="unknown", size=None, rects=[(265, 375, 297, 442)], kind="closet"),
        dict(name="Stairs", floor="unknown", size=None, rects=[(443, 227, 603, 275), (545, 275, 603, 330)],
             kind="stairs"),
    ],
}

WINDOWS = {
    0: [(140, 545, 222, 556), (500, 523, 555, 534), (642, 545, 725, 556), (50, 922, 60, 966),
        (532, 913, 555, 924), (650, 913, 730, 924), (415, 938, 458, 948)],
    1: [(263, 29, 318, 38), (482, 29, 548, 38), (50, 297, 60, 350), (67, 363, 122, 373),
        (343, 444, 393, 453)],
}
RAILINGS = {0: [(540, 773, 546, 823), (599, 773, 606, 823)],
            1: [(603, 227, 609, 335), (470, 275, 545, 281), (539, 281, 545, 335), (545, 330, 603, 335)]}
VOIDS = {1: [(609, 227, 770, 422), (473, 281, 539, 422), (539, 335, 609, 422)]}
FIXTURES = {
    0: [dict(name="Fireplace", rect=(58, 633, 88, 722)), dict(name="Kitchen island", rect=(462, 600, 517, 637))],
}
EXTERIOR_DOORS = {
    0: [dict(name="Front door", at=(507, 918), front=True),
        dict(name="Garage door", at=(220, 1089)),
        dict(name="Sliding door to the backyard", at=(377, 529))],
}

# Pixel rects forced open (door slabs and lines drawn across openings) or
# forced to wall, before the wall finder runs.
CLEAR = {0: [(478, 910, 531, 925), (82, 1083, 360, 1095), (330, 521, 425, 536), (293, 812, 348, 834)]}
WALL = {0: [(455, 689, 462, 718)], 1: [(258, 372, 265, 447)]}

# Guided tour, same format as trace_floorplan.TOUR. Floor 1 points are upper
# drawing pixels. Narration avoids left and right; the app gives directions
# from the walker's heading.
TOUR = [
    (0, 507, 895, "Foyer, just inside the front door. 14 by 10 feet. The stairs up are "
                  "close by, and the living room opens off the foyer with no wall "
                  "between."),
    (0, 560, 860, None),
    (0, 680, 850, "Living room. 11 by 14 feet, with a two story ceiling. Windows on the "
                  "front wall face the street. The dining area is straight through, past "
                  "two columns."),
    (0, 685, 760, None),
    (0, 685, 640, "Dining area. 13 by 11 feet, with a bay in the side wall. A wide "
                  "opening leads into the kitchen."),
    (0, 640, 662, None),
    (0, 545, 662, "Kitchen. 9 by 13 feet. An island in the middle, and the sink under the "
                  "back window."),
    (0, 420, 640, "Breakfast nook. 12 by 13 feet. A sliding door in the back wall leads "
                  "to the yard. No wall between the nook and the family room."),
    (0, 200, 650, "Family room. 16 by 17 feet, fireplace in the far end wall."),
    (0, 322, 660, None),
    (0, 322, 750, "Laundry room, 7 by 8 feet. A door in the far wall goes out to the "
                  "garage."),
    (0, 322, 845, None),
    (0, 220, 950, "Garage. Two car, 23 by 18 feet, concrete. The big garage door is in "
                  "the front wall."),
    (0, 322, 845, None),
    (0, 322, 660, None),
    (0, 430, 665, None),
    (0, 430, 850, "Foyer again, by the front door. The half bath is through the small "
                  "door here. The short hall you just walked joins the foyer to the "
                  "kitchen."),
    (0, 520, 850, None),
    (0, 574, 842, "Stairs to the second floor. They climb toward the back of the house, "
                  "then turn."),
    (0, 574, 795, "climb"),
    (1, 574, 255, None),
    (1, 520, 250, None),
    (1, 400, 250, "Top of the stairs, upstairs hall. Every bedroom and the hall bath open "
                  "off it."),
    (1, 400, 205, None),
    (1, 440, 205, None),
    (1, 500, 130, "Bedroom 2. 18 by 13 feet, with a closet, and a door to the attic in "
                  "the far wall."),
    (1, 440, 205, None),
    (1, 400, 205, None),
    (1, 400, 250, None),
    (1, 350, 250, None),
    (1, 350, 195, "Hall bath, 8 by 7 feet, with a tub."),
    (1, 350, 250, None),
    (1, 250, 250, None),
    (1, 180, 260, "Primary bedroom. 16 by 14 feet, windows on two walls. The primary bath "
                  "is through a door in the back wall."),
    (1, 182, 175, None),
    (1, 182, 110, "Primary bath, 11 by 8 feet. Corner tub and two sinks. A walk-in closet "
                  "opens off one side, the shower room off the other."),
    (1, 182, 175, None),
    (1, 250, 250, None),
    (1, 320, 250, None),
    (1, 320, 330, "Bedroom 3. 12 by 11 feet, at the front of the house."),
]


class Plan(tf.Plan):
    def __init__(self, floor):
        _, self.ppf, self.corner = tf.PLANS[floor]
        g = np.array(Image.open(IMAGE).convert("L")).astype(int)
        # Keep only this level's half of the image.
        if floor == 0:
            g[:490, :] = 255
        else:
            g[470:, :] = 255
            g[395:445, 40:210] = 255   # "UPPER LEVEL" caption
        for x0, y0, x1, y1 in CLEAR.get(floor, []):
            g[y0:y1, x0:x1] = 255
        for x0, y0, x1, y1 in WALL.get(floor, []):
            g[y0:y1, x0:x1] = 0
        self.gray = g


def configure():
    tf.PLANS = {0: ("waterville", PPF, CORNER), 1: ("waterville", PPF, (CORNER[0], CORNER[1] - UPPER_SHIFT))}
    tf.ORIGIN_FT = (2.0, 2.0)
    tf.WIDTH, tf.HEIGHT = 58.0, 44.0
    tf.ROOMS, tf.WINDOWS, tf.RAILINGS, tf.VOIDS = ROOMS, WINDOWS, RAILINGS, VOIDS
    tf.SCREEN_RECTS, tf.SCREEN_LINES = {}, {}
    tf.FIXTURES, tf.EXTERIOR_DOORS, tf.TOUR = FIXTURES, EXTERIOR_DOORS, TOUR
    tf.OUT_DIR = os.path.join(HERE, "out", "waterville")
    tf.Plan = Plan


def main():
    configure()
    floors, grids, front = [], {}, None
    for floor in (0, 1):
        print(f"floor {floor + 1}")
        data, plan, cells = tf.build_floor(floor)
        floors.append(data)
        grids[floor] = cells
        for e in EXTERIOR_DOORS.get(floor, []):
            if e.get("front"):
                fx, fy = plan.to_ft(*e["at"])
                front = dict(floor=floor, x=round(fx, 2), y=round(fy, 2))
    house = dict(
        address="Waterville demo house",
        source="tools/plans/waterville.png",
        summary="3 bedrooms, 2.5 baths, two storeys, with a two car garage.",
        cellSize=tf.CELL, width=tf.WIDTH, height=tf.HEIGHT,
        frontDoor=front, floors=floors, tour=tf.check_tour(grids),
    )
    with open(JSON_OUT, "w") as f:
        json.dump(house, f, separators=(",", ":"))
    print(f"wrote {JSON_OUT} ({os.path.getsize(JSON_OUT) // 1024} KB)")


if __name__ == "__main__":
    main()
