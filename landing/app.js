(() => {
  "use strict";

  // Where demo requests go. Empty means this draft isn't connected yet.
  // For FormSubmit, use "https://formsubmit.co/ajax/<team inbox>".
  const FORM_ENDPOINT = "";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const css = getComputedStyle(document.documentElement);
  const color = (name) => css.getPropertyValue(name).trim();
  const INK = color("--dot") || "#1a2e4e";
  const ACCENT = color("--accent") || "#2747f5";
  const PAPER = color("--paper") || "#f9fbfd";

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

  function ensureAudio() {
    if (!audio) {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return null;
      audio = new Ctx();
    }
    if (audio.state === "suspended") audio.resume();
    return audio;
  }

  function tone({ freq = 440, dur = 0.08, gain = 0.2, type = "sine", pan = 0, at = 0, drop = 0 }) {
    const ctx = ensureAudio();
    if (!ctx) return;
    const t = ctx.currentTime + at;
    const osc = ctx.createOscillator();
    const g = ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, t);
    if (drop) osc.frequency.exponentialRampToValueAtTime(Math.max(30, freq * drop), t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain, t + 0.004);
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
    wall: (pan) => { tone({ freq: 180, dur: 0.09, gain: 0.5, type: "triangle", drop: 0.4, pan }); tone({ freq: 900, dur: 0.02, gain: 0.12, type: "square", pan }); },
    window: (pan) => { tone({ freq: 2600, dur: 0.12, gain: 0.12, pan }); tone({ freq: 3100, dur: 0.12, gain: 0.1, pan, at: 0.09 }); },
    screen: (pan) => { tone({ freq: 400, dur: 0.05, gain: 0.18, type: "triangle", pan }); tone({ freq: 5000, dur: 0.06, gain: 0.02, type: "sawtooth", pan, at: 0.02 }); },
    doorway: (pan) => { tone({ freq: 1200, dur: 0.03, gain: 0.12, pan }); tone({ freq: 1200, dur: 0.03, gain: 0.12, pan, at: 0.11 }); },
    opening: (pan) => tone({ freq: 700, dur: 0.05, gain: 0.08, pan }),
    front: (pan) => {
      [0, 0.14, 0.48].forEach((at) => tone({ freq: 1000, dur: 0.03, gain: 0.12, pan, at }));
      tone({ freq: 660, dur: 0.35, gain: 0.14, pan, at: 0.62 });
      tone({ freq: 880, dur: 0.5, gain: 0.12, pan, at: 0.82 });
    },
    stairs: () => [0, 0.09, 0.18, 0.27, 0.36].forEach((at, i) => tone({ freq: 500 + i * 140, dur: 0.03, gain: 0.1, at })),
    hardwood: () => [0, 0.09, 0.18].forEach((at, i) => tone({ freq: 320, dur: 0.03, gain: 0.12 - i * 0.03, type: "triangle", at })),
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
      feel(key);
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
  if (!PLAN || !canvas || !canvas.getContext) return;

  const ctx = canvas.getContext("2d");
  const readout = document.getElementById("readout");
  const chips = new Map([...document.querySelectorAll("[data-chip]")].map((el) => [el.dataset.chip, el]));
  const W_FT = PLAN.cols * PLAN.cell;
  const H_FT = PLAN.rows * PLAN.cell;
  const RADIUS = 0.6;
  const FLOOR_WORD = { hardwood: "Hardwood", carpet: "Carpet", tile: "Tile", concrete: "Concrete", deck: "Deck" };
  const CELL_KIND = { "#": "wall", w: "window", s: "screen" };
  // Label spots (feet) where the room's centre falls on a wall or the stairs.
  const LABEL_SPOT = { Foyer: [26.4, 39.9], Stairs: [18.6, 34.3] };
  const CONTACT_WORD = { wall: "Wall.", window: "Window.", screen: "Porch screen." };

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
  let staticLayer = null;
  let interacted = false;

  function say(text) {
    readout.textContent = text;
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

  function panFor(x) {
    return ((x - walker.x) / 12) || (x / W_FT) * 2 - 1;
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
    g.fillRect(0, 0, w, h);

    const cellPx = PLAN.cell * scale;
    const dotR = Math.max(1.05, cellPx * 0.36);

    // Raised dots: a soft offset shadow under each, like swell paper.
    g.save();
    g.shadowColor = "rgba(18, 35, 61, 0.35)";
    g.shadowBlur = Math.max(1, cellPx * 0.35);
    g.shadowOffsetX = cellPx * 0.12;
    g.shadowOffsetY = cellPx * 0.22;
    for (let r = 0; r < PLAN.rows; r++) {
      const line = PLAN.grid[r];
      for (let c = 0; c < PLAN.cols; c++) {
        const ch = line[c];
        if (ch === ".") continue;
        const cx = (c + 0.5) * cellPx, cy = (r + 0.5) * cellPx;
        g.beginPath();
        if (ch === "#") {
          g.fillStyle = INK;
          g.arc(cx, cy, dotR, 0, Math.PI * 2);
          g.fill();
        } else if (ch === "w") {
          g.strokeStyle = INK;
          g.lineWidth = Math.max(0.9, dotR * 0.45);
          g.arc(cx, cy, dotR * 0.85, 0, Math.PI * 2);
          g.stroke();
        } else if (ch === "s" && (r + c) % 2 === 0) {
          g.fillStyle = INK;
          g.arc(cx, cy, dotR * 0.5, 0, Math.PI * 2);
          g.fill();
        }
      }
    }
    g.restore();

    // Room labels: print, with braille underneath where it fits.
    const fontPx = Math.max(10, Math.min(15, scale * 1.15));
    g.textAlign = "center";
    g.textBaseline = "alphabetic";
    g.font = `700 ${fontPx}px "Atkinson Hyperlegible Next", system-ui, sans-serif`;
    const bDot = Math.max(1, scale * 0.14);
    const bGap = Math.max(3, scale * 0.36);
    const bAdvance = bGap * 2.6;
    for (const r of rooms) {
      if (r.kind === "closet") continue;
      const label = r.name === "Formal dining room" ? "Dining room" : r.name;
      const boxW = r.w * scale - 6;
      const textW = g.measureText(label).width;
      if (textW > boxW) continue;
      const spot = LABEL_SPOT[r.name];
      const cx = (spot ? spot[0] : r.x + r.w / 2) * scale;
      const cy = (spot ? spot[1] : r.y + r.h / 2) * scale;
      const word = label.toLowerCase();
      const brailleW = word.length * bAdvance - (bAdvance - bGap);
      const y0 = cy + bGap * 0.9;
      // Braille spells the whole label, and only where every dot lands on open floor.
      let showBraille = brailleW <= boxW && r.kind !== "stairs" && r.h * scale > fontPx * 3;
      if (showBraille) {
        let x = cx - brailleW / 2;
        for (const ch of word) {
          for (const d of BRAILLE[ch] || []) {
            const [dx, dy] = DOT_POS[d];
            const fx = (x + dx * bGap) / scale, fy = (y0 + dy * bGap) / scale;
            if (cellAt(fx, fy) !== "." || cellAt(fx + 0.5, fy) !== "." || cellAt(fx - 0.5, fy) !== "." || cellAt(fx, fy + 0.5) !== ".") showBraille = false;
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
  }

  function resize() {
    const rect = canvas.getBoundingClientRect();
    if (!rect.width) return;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    scale = rect.width / W_FT;
    canvas.width = Math.round(rect.width * dpr);
    canvas.height = Math.round(rect.width * (H_FT / W_FT) * dpr);
    drawStatic();
    draw(performance.now());
  }

  function draw(now) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(staticLayer, 0, 0);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    // Footsteps, one every 2.5 ft, the way the app plays floor texture.
    for (const s of steps) {
      const age = (now - s.t) / 2400;
      if (age >= 1) continue;
      ctx.globalAlpha = 0.35 * (1 - age);
      ctx.fillStyle = ACCENT;
      ctx.beginPath();
      ctx.arc(s.x * scale, s.y * scale, Math.max(1.5, scale * 0.18), 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // Haptic rings: wider and brighter the stronger the hit.
    for (const r of rings) {
      const age = (now - r.born) / 650;
      if (age < 0 || age >= 1) continue;
      const ease = reduceMotion ? 1 : 1 - Math.pow(1 - age, 3);
      ctx.globalAlpha = (1 - age) * (0.35 + 0.65 * r.strength);
      ctx.strokeStyle = ACCENT;
      ctx.lineWidth = 1 + r.strength * 2.2;
      ctx.beginPath();
      ctx.arc(r.x * scale, r.y * scale, (0.8 + ease * (1.2 + r.strength * 3.2)) * scale, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // The walker.
    const wx = walker.x * scale, wy = walker.y * scale, wr = Math.max(6, RADIUS * 1.25 * scale);
    ctx.fillStyle = "rgba(39, 71, 245, 0.16)";
    ctx.beginPath();
    ctx.arc(wx, wy, wr * 1.9, 0, Math.PI * 2);
    ctx.fill();
    ctx.shadowColor = "rgba(26, 51, 199, 0.45)";
    ctx.shadowBlur = 6;
    ctx.shadowOffsetY = 2;
    ctx.fillStyle = ACCENT;
    ctx.beginPath();
    ctx.arc(wx, wy, wr, 0, Math.PI * 2);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 2;
    ctx.stroke();

    // A slow invitation pulse until the visitor first moves.
    if (!interacted && !reduceMotion) {
      const p = (now % 1800) / 1800;
      ctx.globalAlpha = 1 - p;
      ctx.strokeStyle = ACCENT;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(wx, wy, wr * (1 + p * 1.8), 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
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
    let touched = null;
    for (let i = 0; i < n; i++) {
      const fx = walker.x + sx, fy = walker.y + sy;
      const hit = blockedBy(fx, fy);
      if (!hit) { walker.x = fx; walker.y = fy; continue; }
      // Push diagonally into a wall and you slide along it.
      if (!blockedBy(fx, walker.y) && Math.abs(sx) > Math.abs(sy) * 0.3) { walker.x = fx; touched = touched || null; continue; }
      if (!blockedBy(walker.x, fy) && Math.abs(sy) > Math.abs(sx) * 0.3) { walker.y = fy; continue; }
      touched = hit;
      const ang = Math.atan2(sy, sx);
      contact(hit, now, walker.x + Math.cos(ang) * RADIUS, walker.y + Math.sin(ang) * RADIUS);
      break;
    }
    if (!touched) contactKind = null;
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

  function toPlan(e) {
    const rect = canvas.getBoundingClientRect();
    return { x: (e.clientX - rect.left) / scale, y: (e.clientY - rect.top) / scale };
  }

  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    target = toPlan(e);
    interacted = true;
    if (soundOn) ensureAudio();
  });
  canvas.addEventListener("pointermove", (e) => { if (target) target = toPlan(e); });
  const endDrag = () => { target = null; contactKind = null; };
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);

  const ARROWS = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] };
  canvas.addEventListener("keydown", (e) => {
    if (ARROWS[e.key]) { e.preventDefault(); keys.add(e.key); interacted = true; }
  });
  canvas.addEventListener("keyup", (e) => { keys.delete(e.key); if (!keys.size) contactKind = null; });
  canvas.addEventListener("blur", () => keys.clear());

  document.getElementById("reset").addEventListener("click", () => {
    walker.x = start.x; walker.y = start.y;
    lastStep = { ...walker };
    steps = []; rings = [];
    room = roomAt(walker.x, walker.y);
    doors.forEach((d) => { d.armed = distToSeg(walker.x, walker.y, d.seg) > 2; });
    say("Foyer, just inside the front door.");
    canvas.focus({ preventScroll: true });
  });

  doors.forEach((d) => { d.armed = distToSeg(walker.x, walker.y, d.seg) > 2; });

  let last = performance.now();
  let visible = true;
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if (target) {
      const dx = target.x - walker.x, dy = target.y - walker.y;
      const dist = Math.hypot(dx, dy);
      if (dist > 0.05) {
        const step = Math.min(dist, 16 * dt);
        moveBy((dx / dist) * step, (dy / dist) * step, now);
      }
    } else if (keys.size) {
      let vx = 0, vy = 0;
      keys.forEach((k) => { vx += ARROWS[k][0]; vy += ARROWS[k][1]; });
      const m = Math.hypot(vx, vy) || 1;
      moveBy((vx / m) * 7 * dt, (vy / m) * 7 * dt, now);
    }
    rings = rings.filter((r) => now - r.born < 700);
    if (visible) draw(now);
    requestAnimationFrame(frame);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; }).observe(canvas);
  }
  if ("ResizeObserver" in window) new ResizeObserver(resize).observe(canvas);
  else window.addEventListener("resize", resize);
  (document.fonts ? document.fonts.ready : Promise.resolve()).then(resize);
  resize();
  requestAnimationFrame(frame);

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
      const res = await fetch(FORM_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ ...data, _subject: "Haptix demo request" }),
      });
      if (!res.ok) throw new Error(String(res.status));
      form.reset();
      status.className = "form-status ok";
      status.textContent = "Thanks. We'll email you within a few days to set a time.";
    } catch (_) {
      status.className = "form-status bad";
      status.textContent = "That didn't send. Check your connection and try again.";
    } finally {
      button.disabled = false;
    }
  });
})();
