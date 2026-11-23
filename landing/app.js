(() => {
  "use strict";

  // Where demo requests go. Empty means this draft isn't connected yet.
  // For FormSubmit, use "https://formsubmit.co/ajax/<team inbox>".
  const FORM_ENDPOINT = "https://formsubmit.co/ajax/haptixteam@gmail.com";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const css = getComputedStyle(document.documentElement);
  const color = (name) => css.getPropertyValue(name).trim();
  const INK = color("--dot") || "#1a2e4e";
  const ACCENT = color("--accent") || "#2747f5";
  const PAPER = color("--paper") || "#f9fbfd";

  /* ---------- Arrival: start once fonts are in, or after 0.7 s ---------- */
  let readyAt = null;
  const markReady = () => {
    if (readyAt !== null) return;
    readyAt = performance.now();
    document.documentElement.classList.add("ready");
  };
  (document.fonts ? document.fonts.ready : Promise.resolve()).then(markReady);
  setTimeout(markReady, 700);

  /* ---------- Braille (uncontracted letters, dots 1-6) ---------- */
  const BRAILLE = {
    a: [1], b: [1, 2], c: [1, 4], d: [1, 4, 5], e: [1, 5], f: [1, 2, 4], g: [1, 2, 4, 5],
    h: [1, 2, 5], i: [2, 4], j: [2, 4, 5], k: [1, 3], l: [1, 2, 3], m: [1, 3, 4],
    n: [1, 3, 4, 5], o: [1, 3, 5], p: [1, 2, 3, 4], q: [1, 2, 3, 4, 5], r: [1, 2, 3, 5],
    s: [2, 3, 4], t: [2, 3, 4, 5], u: [1, 3, 6], v: [1, 2, 3, 6], w: [2, 4, 5, 6],
    x: [1, 3, 4, 6], y: [1, 3, 4, 5, 6], z: [1, 3, 5, 6],
  };
  const DOT_POS = { 1: [0, 0], 2: [0, 1], 3: [0, 2], 4: [1, 0], 5: [1, 1], 6: [1, 2] };

  function brailleSVG(word) {
    const NS = "http://www.w3.org/2000/svg";
    const frag = document.createDocumentFragment();
    for (const ch of word.toLowerCase()) {
      const svg = document.createElementNS(NS, "svg");
      svg.setAttribute("viewBox", "0 0 10 16");
      svg.setAttribute("focusable", "false");
      for (const d of BRAILLE[ch] || []) {
        const [cx, cy] = DOT_POS[d];
        const c = document.createElementNS(NS, "circle");
        c.setAttribute("cx", 2 + cx * 6);
        c.setAttribute("cy", 2 + cy * 6);
        c.setAttribute("r", 1.9);
        svg.appendChild(c);
      }
      frag.appendChild(svg);
    }
    return frag;
  }
  document.querySelectorAll("[data-braille]").forEach((el) => el.appendChild(brailleSVG(el.dataset.braille)));

  /* ---------- Sticky header edge ---------- */
  const header = document.querySelector(".site-header");
  const onScroll = () => header.classList.toggle("scrolled", window.scrollY > 8);
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- Sound (Web Audio, off until asked) ---------- */
  let audio = null;
  let soundOn = false;
  const soundToggle = document.getElementById("sound-toggle");

  // iPhones mute Web Audio when the ringer switch is off. Playing a silent
  // <audio> element first moves the page into the "playback" category.
  let unlocked = false;
  function unlockIOS() {
    if (unlocked) return;
    unlocked = true;
    const rate = 8000, n = 800, buf = new ArrayBuffer(44 + n), v = new DataView(buf);
    const str = (o, t) => [...t].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
    str(0, "RIFF"); v.setUint32(4, 36 + n, true); str(8, "WAVEfmt "); v.setUint32(16, 16, true);
    v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate, true);
    v.setUint16(32, 1, true); v.setUint16(34, 8, true); str(36, "data"); v.setUint32(40, n, true);
    for (let i = 0; i < n; i++) v.setUint8(44 + i, 128);
    const el = document.createElement("audio");
    el.setAttribute("x-webkit-airplay", "deny");
    el.preload = "auto";
    el.loop = true;
    el.src = URL.createObjectURL(new Blob([buf], { type: "audio/wav" }));
    el.play().catch(() => { unlocked = false; });
  }

  function ensureAudio() {
    unlockIOS();
    if (!audio) {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return null;
      audio = new Ctx();
    }
    if (audio.state === "suspended") audio.resume();
    return audio;
  }

  function tone({ freq = 440, dur = 0.08, gain: level = 0.2, type = "sine", pan = 0, at = 0, drop = 0 }) {
    const ctx = ensureAudio();
    if (!ctx) return;
    const t = ctx.currentTime + at;
    const osc = ctx.createOscillator();
    const g = ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, t);
    if (drop) osc.frequency.exponentialRampToValueAtTime(Math.max(30, freq * drop), t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(Math.min(0.9, level * 2), t + 0.004);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    let node = osc.connect(g);
    if (ctx.createStereoPanner) {
      const p = ctx.createStereoPanner();
      p.pan.value = Math.max(-1, Math.min(1, pan));
      node = g.connect(p);
    }
    node.connect(ctx.destination);
    osc.start(t);
    osc.stop(t + dur + 0.02);
  }

  const SOUNDS = {
    wall: (pan) => { tone({ freq: 180, dur: 0.09, gain: 0.5, type: "triangle", drop: 0.4, pan }); tone({ freq: 900, dur: 0.03, gain: 0.12, type: "square", pan }); },
    window: (pan) => { tone({ freq: 2600, dur: 0.12, gain: 0.12, pan }); tone({ freq: 3100, dur: 0.12, gain: 0.1, pan, at: 0.09 }); },
    screen: (pan) => { tone({ freq: 400, dur: 0.05, gain: 0.18, type: "triangle", pan }); tone({ freq: 5000, dur: 0.06, gain: 0.02, type: "sawtooth", pan, at: 0.02 }); },
    doorway: (pan) => { tone({ freq: 1200, dur: 0.05, gain: 0.12, pan }); tone({ freq: 1200, dur: 0.05, gain: 0.12, pan, at: 0.11 }); },
    opening: (pan) => tone({ freq: 700, dur: 0.05, gain: 0.08, pan }),
    front: (pan) => {
      [0, 0.14, 0.48].forEach((at) => tone({ freq: 1000, dur: 0.05, gain: 0.12, pan, at }));
      tone({ freq: 660, dur: 0.35, gain: 0.14, pan, at: 0.62 });
      tone({ freq: 880, dur: 0.5, gain: 0.12, pan, at: 0.82 });
    },
    stairs: () => [0, 0.09, 0.18, 0.27, 0.36].forEach((at, i) => tone({ freq: 500 + i * 140, dur: 0.05, gain: 0.1, at })),
    hardwood: () => [0, 0.09, 0.18].forEach((at, i) => tone({ freq: 320, dur: 0.05, gain: 0.12 - i * 0.03, type: "triangle", at })),
    tile: () => [0, 0.22].forEach((at) => tone({ freq: 520, dur: 0.07, gain: 0.08, at })),
    carpet: () => tone({ freq: 140, dur: 0.3, gain: 0.12 }),
  };

  const VIBRATE = {
    wall: [45], window: [15, 70, 15], screen: [20], doorway: [12, 90, 12], opening: [10],
    front: [12, 120, 12, 320, 12], stairs: [8, 70, 10, 70, 12, 70, 14, 70, 16],
    hardwood: [10, 70, 8, 70, 6], tile: [25, 180, 25], carpet: [60],
  };

  function feel(kind, pan = 0) {
    if (soundOn && SOUNDS[kind]) SOUNDS[kind](pan);
    if (navigator.vibrate && VIBRATE[kind]) {
      try { navigator.vibrate(VIBRATE[kind]); } catch (_) { /* not allowed before a tap */ }
    }
  }

  soundToggle.addEventListener("click", () => {
    soundOn = !soundOn;
    if (soundOn) ensureAudio();
    soundToggle.setAttribute("aria-pressed", String(soundOn));
    soundToggle.querySelector("span").textContent = soundOn ? "Sound on" : "Sound off";
  });

  /* ---------- Haptic vocabulary rhythms ---------- */
  // [ms, size 0-1, ring?] for each beat; carpet is drawn as one swell.
  const PATTERNS = {
    wall: [[0, 1]],
    window: [[0, 0.6, true], [110, 0.6, true]],
    doorway: [[0, 0.45], [120, 0.45]],
    front: [[0, 0.5], [150, 0.5], [500, 0.5]],
    stairs: [[0, 0.3], [100, 0.4], [200, 0.5], [300, 0.6], [400, 0.7]],
    hardwood: [[0, 0.45], [100, 0.35], [200, 0.25]],
    tile: [[0, 0.42], [240, 0.42]],
    carpet: "swell",
  };
  const NAMES = { wall: "wall", window: "window", doorway: "doorway", front: "front door", stairs: "stairs", hardwood: "hardwood", tile: "tile", carpet: "carpet" };

  document.querySelectorAll(".vocab-list li").forEach((li) => {
    const key = li.dataset.pattern;
    const pattern = PATTERNS[key];
    const NS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("class", "rhythm");
    svg.setAttribute("viewBox", "0 0 144 32");
    svg.setAttribute("aria-hidden", "true");
    const beats = [];
    if (pattern === "swell") {
      const path = document.createElementNS(NS, "path");
      path.setAttribute("class", "swell");
      path.setAttribute("d", "M8 16 C 40 4, 104 4, 136 16 C 104 28, 40 28, 8 16 Z");
      svg.appendChild(path);
      beats.push(path);
    } else {
      pattern.forEach(([ms, size, ring]) => {
        const c = document.createElementNS(NS, "circle");
        c.setAttribute("class", ring ? "beat ring" : "beat");
        c.setAttribute("cx", 12 + ms * 0.24);
        c.setAttribute("cy", 16);
        c.setAttribute("r", 3 + size * 8);
        c.dataset.ms = ms;
        svg.appendChild(c);
        beats.push(c);
      });
    }
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "play";
    btn.setAttribute("aria-label", `Play the ${NAMES[key]} pattern`);
    btn.innerHTML = '<svg aria-hidden="true" viewBox="0 0 16 16" width="14" height="14"><path d="M4 2.5v11l9-5.5z" fill="currentColor"/></svg>';
    btn.addEventListener("click", () => {
      // Pressing play is asking for the sound, whatever the map's sound switch says.
      ensureAudio();
      SOUNDS[key]();
      if (navigator.vibrate && VIBRATE[key]) navigator.vibrate(VIBRATE[key]);
      beats.forEach((b) => {
        const ms = Number(b.dataset.ms || 0);
        setTimeout(() => {
          b.classList.remove("on");
          void b.getBoundingClientRect();
          b.classList.add("on");
        }, ms);
      });
    });
    li.append(svg, btn);
  });

  /* ---------- Floor plan explorer ---------- */
  const PLAN = window.HAPTIX_PLAN;
  const canvas = document.getElementById("plan");
  if (PLAN && canvas && canvas.getContext) initExplorer();

  function initExplorer() {
  const ctx = canvas.getContext("2d");
  const readout = document.getElementById("readout");
  const demoNote = document.getElementById("demo-note");
  const earsCanvas = document.getElementById("ears");
  const earsCtx = earsCanvas ? earsCanvas.getContext("2d") : null;
  const earsSource = document.getElementById("ears-source");
  const chips = new Map([...document.querySelectorAll("[data-chip]")].map((el) => [el.dataset.chip, el]));
  const W_FT = PLAN.cols * PLAN.cell;
  const H_FT = PLAN.rows * PLAN.cell;
  const RADIUS = 0.6;
  const FLOOR_WORD = { hardwood: "Hardwood", carpet: "Carpet", tile: "Tile", concrete: "Concrete", deck: "Deck" };
  const CELL_KIND = { "#": "wall", w: "window", s: "screen" };
  // Label spots (feet) where the room's centre falls on a wall or the stairs.
  const LABEL_SPOT = { Foyer: [26.4, 39.9], Stairs: [18.6, 34.3] };
  const CONTACT_WORD = { wall: "Wall.", window: "Window.", screen: "Porch screen." };
  // The demo walk: front door, kitchen, dining area, family room, porch.
  const DEMO_PATH = [[22.4, 39.6], [27.4, 38.6], [27.4, 31], [27.4, 25.5], [22, 22], [33, 21.5], [45, 20], [48.4, 15.5], [46.5, 10]];

  const rooms = PLAN.rooms.map((r, i) => ({ ...r, i, x: r.bounds[0], y: r.bounds[1], w: r.bounds[2], h: r.bounds[3], area: r.bounds[2] * r.bounds[3] }));

  function cellAt(x, y) {
    const c = Math.floor(x / PLAN.cell);
    const r = Math.floor(y / PLAN.cell);
    if (r < 0 || r >= PLAN.rows || c < 0 || c >= PLAN.cols) return ".";
    return PLAN.grid[r][c];
  }

  function blockedBy(x, y) {
    if (x < RADIUS || y < RADIUS || x > W_FT - RADIUS || y > H_FT - RADIUS) return "wall";
    const c0 = Math.floor((x - RADIUS) / PLAN.cell), c1 = Math.floor((x + RADIUS) / PLAN.cell);
    const r0 = Math.floor((y - RADIUS) / PLAN.cell), r1 = Math.floor((y + RADIUS) / PLAN.cell);
    for (let r = r0; r <= r1; r++) {
      for (let c = c0; c <= c1; c++) {
        const ch = PLAN.grid[r] && PLAN.grid[r][c];
        if (!ch || ch === ".") continue;
        const nx = Math.max(c * PLAN.cell, Math.min(x, (c + 1) * PLAN.cell));
        const ny = Math.max(r * PLAN.cell, Math.min(y, (r + 1) * PLAN.cell));
        if ((nx - x) ** 2 + (ny - y) ** 2 < RADIUS * RADIUS) return CELL_KIND[ch] || "wall";
      }
    }
    return null;
  }

  // Each door is a segment. Its direction comes from which neighbours are wall.
  const doors = PLAN.doors.map((d) => {
    const half = d.width / 2;
    const horizontal = cellAt(d.x - half - 0.4, d.y) !== "." || cellAt(d.x + half + 0.4, d.y) !== ".";
    const seg = horizontal
      ? [d.x - half, d.y, d.x + half, d.y]
      : [d.x, d.y - half, d.x, d.y + half];
    const kind = d.kind === "exterior" ? (d.name === "Front door" ? "front" : "exterior") : d.kind;
    return { ...d, seg, kind, armed: true };
  });
  const frontDoor = doors.find((d) => d.kind === "front");
  const frontPoint = frontDoor
    ? { x: (frontDoor.seg[0] + frontDoor.seg[2]) / 2, y: (frontDoor.seg[1] + frontDoor.seg[3]) / 2 }
    : { x: PLAN.front.x, y: PLAN.front.y };

  function distToSeg(px, py, [x1, y1, x2, y2]) {
    const dx = x2 - x1, dy = y2 - y1;
    const t = Math.max(0, Math.min(1, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy || 1)));
    return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
  }

  function roomAt(x, y) {
    let best = null;
    for (const r of rooms) {
      if (x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h && (!best || r.area < best.area)) best = r;
    }
    return best;
  }

  /* State */
  const start = { x: PLAN.start.x, y: PLAN.start.y };
  const walker = { x: start.x, y: start.y };
  const heading = { x: 0, y: -1 };
  let target = null;
  const keys = new Set();
  let rings = [];
  let steps = [];
  let lastStep = { x: walker.x, y: walker.y };
  let contactKind = null;
  let lastKnock = 0;
  let lastWallSay = 0;
  let room = roomAt(walker.x, walker.y);
  let pendingRoom = null;
  let pendingSince = 0;
  let scale = 1;
  let dpr = 1;
  let rotated = false;
  let staticLayer = null;
  let interacted = false;
  let printStart = reduceMotion ? -1e9 : null;
  const PRINT_MS = 1900;
  let demo = reduceMotion ? null : { i: 0, pauseUntil: 0, lastProgress: 0, best: Infinity };
  let lastMoveAt = -1e9;
  let lastBeacon = -1e9;

  // On phones the plan stands upright so it can be drawn bigger.
  const narrow = window.matchMedia("(max-width: 640px)");
  const toScreen = (x, y) => (rotated ? [(H_FT - y) * scale, x * scale] : [x * scale, y * scale]);
  const toPlanXY = (X, Y) => (rotated ? [Y / scale, H_FT - X / scale] : [X / scale, Y / scale]);
  const screenDirToPlan = (sx, sy) => (rotated ? [sy, -sx] : [sx, sy]);

  /* What the two ears hear: the front door chime placed in 3D, and speech in both. */
  const EAR_SAMPLES = 56;
  const earL = new Array(EAR_SAMPLES).fill(0);
  const earR = new Array(EAR_SAMPLES).fill(0);
  let levelL = 0, levelR = 0, lastEarTick = 0, sourceUntil = 0;

  function hear(l, r, source, ms = 700) {
    levelL = Math.min(1, Math.max(levelL, l));
    levelR = Math.min(1, Math.max(levelR, r));
    if (earsSource && source) {
      earsSource.textContent = source;
      sourceUntil = performance.now() + ms;
    }
  }

  function beacon(now) {
    const dx = frontPoint.x - walker.x, dy = frontPoint.y - walker.y;
    const dist = Math.hypot(dx, dy) || 1;
    // Positive means the door is to the walker's right (y grows downward).
    const rel = Math.atan2(heading.x * dy - heading.y * dx, heading.x * dx + heading.y * dy);
    const pan = Math.sin(rel);
    const vol = Math.max(0.3, Math.min(1, 1.15 - dist / 45));
    const a = ((pan + 1) * Math.PI) / 4;
    hear(vol * Math.cos(a), vol * Math.sin(a), "Front door chime");
    if (soundOn) {
      tone({ freq: 660, dur: 0.22, gain: 0.07 * vol, pan });
      tone({ freq: 880, dur: 0.3, gain: 0.06 * vol, pan, at: 0.16 });
    }
    lastBeacon = now;
  }

  function say(text) {
    readout.textContent = text;
    hear(0.55, 0.55, "Voice", 900);
  }

  function light(chip) {
    const el = chips.get(chip);
    if (!el) return;
    el.classList.add("lit");
    clearTimeout(el._t);
    el._t = setTimeout(() => el.classList.remove("lit"), 450);
  }

  function ring(x, y, strength, delay = 0) {
    rings.push({ x, y, strength, born: performance.now() + delay });
  }

  /* Static layer: the tactile drawing */
  function drawStatic() {
    const w = canvas.width, h = canvas.height;
    staticLayer = document.createElement("canvas");
    staticLayer.width = w;
    staticLayer.height = h;
    const g = staticLayer.getContext("2d");
    g.scale(dpr, dpr);
    g.fillStyle = PAPER;
    g.fillRect(0, 0, w / dpr, h / dpr);

    const cellPx = PLAN.cell * scale;
    const dotR = Math.max(1.05, cellPx * 0.36);

    // Raised dots: each kind is drawn once with its soft offset shadow, like
    // swell paper, then stamped. Per-dot canvas shadows are slow on phones.
    const blur = Math.max(1, cellPx * 0.35), offX = cellPx * 0.12, offY = cellPx * 0.22;
    function sprite(paint, radius) {
      const half = radius + blur * 2 + Math.max(offX, offY);
      const size = Math.ceil(half * 2 * dpr);
      const c = document.createElement("canvas");
      c.width = c.height = size;
      const sg = c.getContext("2d");
      sg.scale(dpr, dpr);
      sg.shadowColor = "rgba(18, 35, 61, 0.35)";
      sg.shadowBlur = blur * dpr;
      sg.shadowOffsetX = offX * dpr;
      sg.shadowOffsetY = offY * dpr;
      sg.beginPath();
      paint(sg, half, half);
      return { c, half: size / dpr / 2 };
    }
    const SPRITES = {
      "#": sprite((sg, x, y) => { sg.fillStyle = INK; sg.arc(x, y, dotR, 0, Math.PI * 2); sg.fill(); }, dotR),
      w: sprite((sg, x, y) => { sg.strokeStyle = INK; sg.lineWidth = Math.max(0.9, dotR * 0.45); sg.arc(x, y, dotR * 0.85, 0, Math.PI * 2); sg.stroke(); }, dotR),
      s: sprite((sg, x, y) => { sg.fillStyle = INK; sg.arc(x, y, dotR * 0.5, 0, Math.PI * 2); sg.fill(); }, dotR * 0.5),
    };
    for (let r = 0; r < PLAN.rows; r++) {
      const line = PLAN.grid[r];
      for (let c = 0; c < PLAN.cols; c++) {
        const ch = line[c];
        if (ch === "." || (ch === "s" && (r + c) % 2)) continue;
        const sp = SPRITES[ch];
        if (!sp) continue;
        const [sx, sy] = toScreen((c + 0.5) * PLAN.cell, (r + 0.5) * PLAN.cell);
        g.drawImage(sp.c, sx - sp.half, sy - sp.half, sp.half * 2, sp.half * 2);
      }
    }

    g.save();
    if (rotated) { g.translate(H_FT * scale, 0); g.rotate(Math.PI / 2); }

    // Entrance mark: the tactile-map convention of a solid triangle.
    const fd = PLAN.front;
    const tx = fd.x * scale, ty = (fd.y + 1.6) * scale, ts = Math.max(5, scale * 0.8);
    g.fillStyle = ACCENT;
    g.beginPath();
    g.moveTo(tx, ty - ts);
    g.lineTo(tx - ts, ty + ts * 0.6);
    g.lineTo(tx + ts, ty + ts * 0.6);
    g.closePath();
    g.fill();
    g.restore();

    // Room labels stay upright: print, with braille underneath where it fits.
    const fontPx = Math.max(10.5, Math.min(15, scale * 1.15));
    g.textAlign = "center";
    g.textBaseline = "alphabetic";
    g.font = `700 ${fontPx}px "Atkinson Hyperlegible Next", system-ui, sans-serif`;
    const bDot = Math.max(1, scale * 0.14);
    const bGap = Math.max(3, scale * 0.36);
    const bAdvance = bGap * 2.6;
    for (const r of rooms) {
      if (r.kind === "closet" || (rotated && r.kind === "stairs")) continue;
      const label = r.name === "Formal dining room" ? "Dining room" : r.name;
      const boxW = (rotated ? r.h : r.w) * scale - 6;
      const boxH = (rotated ? r.w : r.h) * scale;
      if (g.measureText(label).width > boxW) continue;
      const spot = LABEL_SPOT[r.name] || [r.x + r.w / 2, r.y + r.h / 2];
      const [cx, cy] = toScreen(spot[0], spot[1]);
      const word = label.toLowerCase();
      const brailleW = word.length * bAdvance - (bAdvance - bGap);
      const y0 = cy + bGap * 0.9;
      // Braille spells the whole label, and only where every dot lands on open floor.
      let showBraille = brailleW <= boxW && r.kind !== "stairs" && boxH > fontPx * 3;
      if (showBraille) {
        let x = cx - brailleW / 2;
        for (const ch of word) {
          for (const d of BRAILLE[ch] || []) {
            const [dx, dy] = DOT_POS[d];
            const [fx, fy] = toPlanXY(x + dx * bGap, y0 + dy * bGap);
            if (cellAt(fx, fy) !== "." || cellAt(fx + 0.5, fy) !== "." || cellAt(fx - 0.5, fy) !== "." || cellAt(fx, fy + 0.5) !== "." || cellAt(fx, fy - 0.5) !== ".") showBraille = false;
          }
          x += bAdvance;
        }
      }
      g.fillStyle = INK;
      g.fillText(label, cx, cy + (showBraille ? -bGap * 0.4 : fontPx * 0.35));
      if (showBraille) {
        g.fillStyle = "rgba(26, 46, 78, 0.72)";
        let x0 = cx - brailleW / 2;
        for (const ch of word) {
          for (const d of BRAILLE[ch] || []) {
            const [dx, dy] = DOT_POS[d];
            g.beginPath();
            g.arc(x0 + dx * bGap, y0 + dy * bGap, bDot, 0, Math.PI * 2);
            g.fill();
          }
          x0 += bAdvance;
        }
      }
    }
  }

  let lastSizeKey = "";
  let planInView = false;
  let fontsReady = false;
  function resize() {
    rotated = narrow.matches;
    const across = rotated ? H_FT : W_FT, down = rotated ? W_FT : H_FT;
    canvas.style.aspectRatio = `${across} / ${down}`;
    const rect = canvas.getBoundingClientRect();
    if (!rect.width) return;
    const nextDpr = Math.min(window.devicePixelRatio || 1, 2);
    const key = `${rect.width}|${rotated}|${nextDpr}|${fontsReady}`;
    if (key === lastSizeKey) return;
    lastSizeKey = key;
    dpr = nextDpr;
    scale = rect.width / across;
    canvas.width = Math.round(rect.width * dpr);
    canvas.height = Math.round(rect.width * (down / across) * dpr);
    drawStatic();
    if (earsCanvas) {
      const er = earsCanvas.getBoundingClientRect();
      earsCanvas.width = Math.round(er.width * dpr);
      earsCanvas.height = Math.round(er.height * dpr);
    }
    draw(performance.now());
  }

  const easeOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

  function draw(now) {
    const W = canvas.width, H = canvas.height;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = PAPER;
    ctx.fillRect(0, 0, W, H);

    // The plan prints in from the top, like an embosser's head passing down the sheet.
    const printing = printStart === null || now - printStart < PRINT_MS;
    const p = printStart === null ? 0 : easeOut(Math.min(1, (now - printStart) / PRINT_MS));
    if (p > 0) {
      const sh = Math.max(1, Math.round(H * p));
      ctx.drawImage(staticLayer, 0, 0, W, sh, 0, 0, W, sh);
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (printing) {
      if (printStart !== null) {
        const y = (H / dpr) * p;
        const grad = ctx.createLinearGradient(0, y - 18, 0, y + 2);
        grad.addColorStop(0, "rgba(39, 71, 245, 0)");
        grad.addColorStop(1, "rgba(39, 71, 245, 0.22)");
        ctx.fillStyle = grad;
        ctx.fillRect(0, y - 18, W / dpr, 20);
        ctx.fillStyle = ACCENT;
        ctx.fillRect(0, y - 1, W / dpr, 2);
      }
      return;
    }

    // Footsteps, one every 2.5 ft, the way the app plays floor texture.
    for (const s of steps) {
      const age = (now - s.t) / 2400;
      if (age >= 1) continue;
      const [sx, sy] = toScreen(s.x, s.y);
      ctx.globalAlpha = 0.35 * (1 - age);
      ctx.fillStyle = ACCENT;
      ctx.beginPath();
      ctx.arc(sx, sy, Math.max(1.5, scale * 0.18), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // Haptic rings: wider and brighter the stronger the hit.
    for (const r of rings) {
      const age = (now - r.born) / 650;
      if (age < 0 || age >= 1) continue;
      const ease = reduceMotion ? 1 : 1 - Math.pow(1 - age, 3);
      const [rx, ry] = toScreen(r.x, r.y);
      ctx.globalAlpha = (1 - age) * (0.35 + 0.65 * r.strength);
      ctx.strokeStyle = ACCENT;
      ctx.lineWidth = 1 + r.strength * 2.2;
      ctx.beginPath();
      ctx.arc(rx, ry, (0.8 + ease * (1.2 + r.strength * 3.2)) * scale, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // The walker fades in once the print finishes, with a nose showing its heading.
    const appear = reduceMotion ? 1 : Math.min(1, (now - printStart - PRINT_MS) / 350);
    const [wx, wy] = toScreen(walker.x, walker.y);
    const wr = Math.max(6, RADIUS * 1.25 * scale);
    const [hx, hy] = rotated ? [-heading.y, heading.x] : [heading.x, heading.y];
    ctx.globalAlpha = appear;
    ctx.fillStyle = "rgba(39, 71, 245, 0.16)";
    ctx.beginPath();
    ctx.arc(wx, wy, wr * 1.9, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = ACCENT;
    ctx.beginPath();
    const ang = Math.atan2(hy, hx);
    ctx.moveTo(wx + Math.cos(ang) * wr * 1.75, wy + Math.sin(ang) * wr * 1.75);
    ctx.lineTo(wx + Math.cos(ang + 0.7) * wr * 0.9, wy + Math.sin(ang + 0.7) * wr * 0.9);
    ctx.lineTo(wx + Math.cos(ang - 0.7) * wr * 0.9, wy + Math.sin(ang - 0.7) * wr * 0.9);
    ctx.closePath();
    ctx.fill();
    ctx.shadowColor = "rgba(26, 51, 199, 0.45)";
    ctx.shadowBlur = 6 * dpr;
    ctx.shadowOffsetY = 2 * dpr;
    ctx.beginPath();
    ctx.arc(wx, wy, wr, 0, Math.PI * 2);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 2;
    ctx.stroke();

    // After the demo, a slow pulse invites the visitor to take over.
    if (!interacted && !demo && !reduceMotion) {
      const q = (now % 1800) / 1800;
      ctx.globalAlpha = 1 - q;
      ctx.strokeStyle = ACCENT;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(wx, wy, wr * (1 + q * 1.8), 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  function drawEars(now) {
    if (!earsCtx || !earsCanvas.width) return;
    if (now - lastEarTick > 45) {
      lastEarTick = now;
      earL.shift(); earL.push(levelL);
      earR.shift(); earR.push(levelR);
      levelL *= 0.8; levelR *= 0.8;
      if (earsSource && now > sourceUntil && earsSource.textContent) earsSource.textContent = "";
    }
    const W = earsCanvas.width, H = earsCanvas.height;
    earsCtx.clearRect(0, 0, W, H);
    const rowH = H / 2, bw = W / EAR_SAMPLES;
    [earL, earR].forEach((row, k) => {
      const mid = rowH * k + rowH / 2;
      for (let i = 0; i < EAR_SAMPLES; i++) {
        const v = row[i];
        const hgt = Math.max(1.5 * dpr, v * (rowH - 6 * dpr));
        earsCtx.fillStyle = v > 0.04 ? ACCENT : "rgba(58, 74, 98, 0.28)";
        earsCtx.globalAlpha = 0.35 + 0.65 * (i / EAR_SAMPLES);
        earsCtx.fillRect(i * bw + bw * 0.2, mid - hgt / 2, bw * 0.6, hgt);
      }
    });
    earsCtx.globalAlpha = 1;
  }

  function contact(kind, now, x, y) {
    const isNew = contactKind !== kind;
    if (isNew || now - lastKnock > 300) {
      lastKnock = now;
      ring(x, y, kind === "wall" ? 1 : 0.6);
      if (kind === "window") ring(x, y, 0.6, 110);
      light(kind === "screen" ? "wall" : kind);
      feel(kind, 0);
      if (isNew || now - lastWallSay > 1500) {
        lastWallSay = now;
        say(CONTACT_WORD[kind] || "Wall.");
      }
    }
    contactKind = kind;
  }

  function moveBy(dx, dy, now) {
    const dist = Math.hypot(dx, dy);
    if (dist < 1e-4) return;
    const n = Math.ceil(dist / 0.12);
    const sx = dx / n, sy = dy / n;
    const before = { x: walker.x, y: walker.y };
    let touched = null;
    for (let i = 0; i < n; i++) {
      const fx = walker.x + sx, fy = walker.y + sy;
      const hit = blockedBy(fx, fy);
      if (!hit) { walker.x = fx; walker.y = fy; continue; }
      // Push diagonally into a wall and you slide along it.
      if (!blockedBy(fx, walker.y) && Math.abs(sx) > Math.abs(sy) * 0.3) { walker.x = fx; continue; }
      if (!blockedBy(walker.x, fy) && Math.abs(sy) > Math.abs(sx) * 0.3) { walker.y = fy; continue; }
      touched = hit;
      const ang = Math.atan2(sy, sx);
      contact(hit, now, walker.x + Math.cos(ang) * RADIUS, walker.y + Math.sin(ang) * RADIUS);
      break;
    }
    if (!touched) contactKind = null;
    // Heading eases toward the way the walker is going.
    const mx = walker.x - before.x, my = walker.y - before.y, m = Math.hypot(mx, my);
    if (m > 1e-3) {
      heading.x += (mx / m - heading.x) * 0.25;
      heading.y += (my / m - heading.y) * 0.25;
      const hl = Math.hypot(heading.x, heading.y) || 1;
      heading.x /= hl; heading.y /= hl;
      lastMoveAt = now;
    }
    afterMove(now);
  }

  function afterMove(now) {
    if (Math.hypot(walker.x - lastStep.x, walker.y - lastStep.y) >= 2.5) {
      lastStep = { x: walker.x, y: walker.y };
      steps.push({ x: walker.x, y: walker.y, t: now });
      if (steps.length > 16) steps.shift();
    }

    for (const d of doors) {
      const dist = distToSeg(walker.x, walker.y, d.seg);
      if (d.armed && dist < 1) {
        d.armed = false;
        const mx = (d.seg[0] + d.seg[2]) / 2, my = (d.seg[1] + d.seg[3]) / 2;
        if (d.kind === "front") {
          ring(mx, my, 0.5); ring(mx, my, 0.5, 150); ring(mx, my, 0.5, 500);
          light("front"); feel("front", 0); say("Front door.");
        } else if (d.kind === "opening") {
          ring(mx, my, 0.3); light("opening"); feel("opening", 0);
          const other = rooms[d.a === (room && room.i) ? d.b : d.a];
          if (other) say(`Opening to ${other.name}.`);
        } else if (d.kind === "doorway") {
          ring(mx, my, 0.42); ring(mx, my, 0.42, 120); light("doorway"); feel("doorway", 0);
          const other = rooms[d.a === (room && room.i) ? d.b : d.a];
          if (other) say(`Door to ${other.name}.`);
        } else {
          ring(mx, my, 0.42); ring(mx, my, 0.42, 120); light("doorway"); feel("doorway", 0);
          say(`${d.name}.`);
        }
      } else if (!d.armed && dist > 2) {
        d.armed = true;
      }
    }

    // A room is announced once you've settled in it, so a doorway doesn't chatter.
    const here = roomAt(walker.x, walker.y);
    if (here !== room) {
      if (pendingRoom !== here) { pendingRoom = here; pendingSince = now; }
      else if (now - pendingSince > 350) {
        room = here;
        pendingRoom = null;
        if (here) {
          const floor = FLOOR_WORD[here.floor];
          say(floor ? `${here.name}. ${floor}.` : `${here.name}.`);
        } else {
          say("Outside.");
        }
      }
    } else {
      pendingRoom = null;
    }
  }

  // The demo is silent for screen readers: they hear only what the visitor does.
  function startDemoAnnouncements() {
    readout.setAttribute("aria-live", "off");
    if (demoNote) demoNote.hidden = false;
  }

  function takeOver() {
    interacted = true;
    if (demo) endDemo(false);
    if (printStart === null) printStart = performance.now() - PRINT_MS;
  }

  function endDemo(finished) {
    demo = null;
    target = null;
    readout.setAttribute("aria-live", "polite");
    if (demoNote) demoNote.hidden = true;
    if (finished) say("Your turn. Drag the dot.");
  }

  function toPlan(e) {
    const rect = canvas.getBoundingClientRect();
    const [x, y] = toPlanXY(e.clientX - rect.left, e.clientY - rect.top);
    return { x, y };
  }

  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    takeOver();
    target = toPlan(e);
    if (soundOn) ensureAudio();
  });
  canvas.addEventListener("pointermove", (e) => { if (target && !demo) target = toPlan(e); });
  const endDrag = () => { if (!demo) target = null; contactKind = null; };
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);

  const ARROWS = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] };
  canvas.addEventListener("keydown", (e) => {
    if (ARROWS[e.key]) { e.preventDefault(); takeOver(); keys.add(e.key); }
  });
  canvas.addEventListener("keyup", (e) => { keys.delete(e.key); if (!keys.size) contactKind = null; });
  canvas.addEventListener("blur", () => keys.clear());

  document.getElementById("reset").addEventListener("click", () => {
    takeOver();
    walker.x = start.x; walker.y = start.y;
    heading.x = 0; heading.y = -1;
    lastStep = { ...walker };
    steps = []; rings = [];
    room = roomAt(walker.x, walker.y);
    doors.forEach((d) => { d.armed = distToSeg(walker.x, walker.y, d.seg) > 2; });
    say("Foyer, just inside the front door.");
    canvas.focus({ preventScroll: true });
  });

  doors.forEach((d) => { d.armed = distToSeg(walker.x, walker.y, d.seg) > 2; });
  if (demo) startDemoAnnouncements();

  let last = performance.now();
  let visible = true;
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    // Print the plan once the card has risen in and most of it is on screen.
    if (printStart === null && planInView && readyAt !== null && now - readyAt > 450) printStart = now;
    const printed = printStart !== null && now - printStart >= PRINT_MS;

    if (demo && printed && now >= demo.pauseUntil) {
      const [tx, ty] = DEMO_PATH[demo.i];
      const dx = tx - walker.x, dy = ty - walker.y, dist = Math.hypot(dx, dy);
      if (dist < 0.2 || now - demo.lastProgress > 1500) {
        demo.i += 1;
        demo.best = Infinity;
        demo.lastProgress = now;
        demo.pauseUntil = now + 260;
        if (demo.i >= DEMO_PATH.length) endDemo(true);
      } else {
        if (dist < demo.best - 0.05) { demo.best = dist; demo.lastProgress = now; }
        const step = Math.min(dist, 6.5 * dt);
        moveBy((dx / dist) * step, (dy / dist) * step, now);
      }
    } else if (target && !demo) {
      const dx = target.x - walker.x, dy = target.y - walker.y;
      const dist = Math.hypot(dx, dy);
      if (dist > 0.05) {
        const step = Math.min(dist, 16 * dt);
        moveBy((dx / dist) * step, (dy / dist) * step, now);
      }
    } else if (keys.size) {
      let vx = 0, vy = 0;
      keys.forEach((k) => { vx += ARROWS[k][0]; vy += ARROWS[k][1]; });
      const [px, py] = screenDirToPlan(vx, vy);
      const m = Math.hypot(px, py) || 1;
      moveBy((px / m) * 7 * dt, (py / m) * 7 * dt, now);
    }

    // Like the app, the front door chime plays every 1.5 s while you're moving.
    if (printed && now - lastMoveAt < 400 && now - lastBeacon > 1500) beacon(now);

    rings = rings.filter((r) => now - r.born < 700);
    if (visible) { draw(now); drawEars(now); }
    requestAnimationFrame(frame);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      planInView = entry.intersectionRatio >= 0.45;
    }, { threshold: [0, 0.45] }).observe(canvas);
  } else {
    planInView = true;
  }
  if ("ResizeObserver" in window) new ResizeObserver(resize).observe(canvas);
  else window.addEventListener("resize", resize);
  narrow.addEventListener && narrow.addEventListener("change", resize);
  (document.fonts ? document.fonts.ready : Promise.resolve()).then(() => { fontsReady = true; resize(); });
  resize();
  requestAnimationFrame(frame);
  }

  /* ---------- Demo form ---------- */
  const form = document.getElementById("demo-form");
  const status = document.getElementById("form-status");

  function check(input) {
    const err = document.getElementById(`${input.id}-error`);
    const ok = input.checkValidity() && input.value.trim() !== "";
    input.setAttribute("aria-invalid", String(!ok));
    if (err) err.hidden = ok;
    return ok;
  }

  form.querySelectorAll("input[required]").forEach((input) => {
    input.addEventListener("blur", () => { if (input.value) check(input); });
    input.addEventListener("input", () => { if (input.getAttribute("aria-invalid") === "true") check(input); });
  });

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const required = [...form.querySelectorAll("input[required]")];
    const bad = required.filter((input) => !check(input));
    if (bad.length) {
      bad[0].focus();
      status.className = "form-status bad";
      status.textContent = "Check the fields marked above.";
      return;
    }
    const data = Object.fromEntries(new FormData(form));
    if (data._honey) return;
    if (!FORM_ENDPOINT) {
      status.className = "form-status bad";
      status.textContent = "This draft isn't connected to our inbox yet, so nothing was sent.";
      return;
    }
    const button = form.querySelector("button[type=submit]");
    button.disabled = true;
    status.className = "form-status";
    status.textContent = "Sending...";
    try {
      // Give up after 15 s so a slow form service never leaves "Sending..." up forever.
      const timeout = new AbortController();
      const timer = setTimeout(() => timeout.abort(), 15000);
      const res = await fetch(FORM_ENDPOINT, {
        signal: timeout.signal,
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ ...data, _subject: "Haptix demo request" }),
      });
      clearTimeout(timer);
      if (!res.ok) throw new Error(String(res.status));
      form.reset();
      status.className = "form-status ok";
      status.textContent = "Thanks. We'll email you within a few days to set a time.";
    } catch (_) {
      status.className = "form-status bad";
      status.textContent = "That didn't send. Try again, or email us at haptixteam@gmail.com.";
    } finally {
      button.disabled = false;
    }
  });
})();
