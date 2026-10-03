import Foundation
import Network

/// A tiny web server on the phone so a laptop on the same Wi-Fi can watch the
/// avatar move on the floor plan while the phone itself stays blank. Open
/// http://<phone IP>:8080 in a browser. The page polls /state ten times a second.
final class LaptopViewer {
    static let port: UInt16 = 8080

    struct Snapshot: Encodable {
        var floor = 0
        var x = 0.0
        var y = 0.0
        var heading = 0.0  // radians, 0 = up the plan, clockwise
        var room = ""
        var house = ""     // which house file is loaded; the page refetches it when this changes
        var touring = false
        var onRail = true  // the avatar is locked to the route
        var said = ""
        var saidAt = 0.0   // seconds since 1970, so the page can fade old lines
        var events: [Event] = []   // the latest haptics and sounds, for the visualizer panel
        var left = 0.0     // measured output level per ear, RMS 0 to 1
        var right = 0.0
        var speaking = false
    }

    /// One vibration or sound. The page skips ids it has already drawn.
    struct Event: Encodable {
        let id: Int
        let kind: String   // "haptic" or "sound"
        let name: String
        let level: Double  // 0 to 1
        var pan = 0.0      // -1 left ear only, 0 both, 1 right ear only
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "laptop-viewer")
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var nextEvent = 0
    private var houseJSON = Data()   // guarded by `lock`, like `snapshot`
    /// Served at /transcript. Set before `start`.
    var transcript: Transcript?

    /// Serves `demo`'s house file from now on, and tells open pages to reload it.
    func show(_ demo: DemoHouse) {
        let data = demo.json
        lock.lock()
        houseJSON = data
        lock.unlock()
        update { $0.house = demo.rawValue }
    }

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("Laptop viewer failed: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("Laptop viewer couldn't listen: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Called on main whenever something the laptop shows changes.
    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&snapshot)
        lock.unlock()
    }

    /// A haptic or sound the phone just played. The page polls every 100 ms, so
    /// the last few are kept rather than only the newest.
    func record(_ kind: String, _ name: String, level: Float, pan: Float = 0) {
        update {
            nextEvent += 1
            $0.events.append(Event(id: nextEvent, kind: kind, name: name, level: Double(level), pan: Double(pan)))
            if $0.events.count > 24 { $0.events.removeFirst($0.events.count - 24) }
        }
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // "GET /transcript?after=4 HTTP/1.1" -> "/transcript", ["after": "4"]
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let url = URLComponents(string: target)
            let path = url?.path ?? "/"
            let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
            let (body, type): (Data, String)
            var extraHeaders = ""
            switch path {
            case "/transcript":
                let after = query["after"].flatMap(Int.init) ?? -1
                let entries = self.transcript?.entries(after: after) ?? []
                (body, type) = ((try? JSONEncoder().encode(entries)) ?? Data(), "application/json")
            case "/transcript.txt":
                (body, type) = (Data((self.transcript?.text ?? "").utf8), "text/plain; charset=utf-8")
                let name = self.transcript?.fileName ?? "House Tour transcript.txt"
                extraHeaders = "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
            case "/house.json":
                self.lock.lock()
                let json = self.houseJSON
                self.lock.unlock()
                (body, type) = (json, "application/json")
            case "/state":
                self.lock.lock()
                let current = self.snapshot
                self.lock.unlock()
                (body, type) = ((try? JSONEncoder().encode(current)) ?? Data(), "application/json")
            default:
                (body, type) = (Data(viewerPage.utf8), "text/html; charset=utf-8")
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                + extraHeaders + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: Address

    /// The phone's IPv4 addresses on Wi-Fi (en0) and Personal Hotspot (bridge*).
    static func addresses() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    static var urls: [String] { addresses().map { "http://\($0):\(port)" } }
}

/// The page the laptop loads. It draws the plan from the same house.json the
/// app uses, so the two can't disagree.
private let viewerPage = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>House Tour · Live viewer</title>
<style>
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{background:#fff;color:#111;font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;display:grid;grid-template-rows:auto minmax(0,1fr) auto;
  grid-template-columns:minmax(0,1fr) 380px}
header,.split,footer{grid-column:1}
#log{grid-column:2;grid-row:1/-1;border-left:1px solid #eee;display:flex;flex-direction:column;min-height:0}
#log h2{display:flex;justify-content:space-between;align-items:baseline;margin:0;padding:22px 20px 12px;
  font-size:12px;font-weight:500;color:#8a8a8a}
#log h2 a{color:#2563eb;text-decoration:none}
#lines{list-style:none;margin:0;padding:0 20px 20px;overflow-y:auto;flex:1}
#lines li{padding:7px 0;border-bottom:1px solid #f3f3f3}
#lines .meta{font-size:11px;color:#a3a3a3}
#lines .you .meta b{color:#c2410c}#lines .app .meta b{color:#2563eb}#lines .skipped{opacity:.55}#lines .event{opacity:.55;font-size:.9em}
header{display:flex;justify-content:space-between;gap:16px;padding:22px 36px;font-size:12px;color:#8a8a8a}
#status{display:flex;gap:8px;align-items:center;color:#2563eb}
#status::before{content:'';width:6px;height:6px;border-radius:50%;background:currentColor}
#status.off{color:#8a8a8a}
.split{display:grid;grid-template-columns:minmax(0,1.5fr) minmax(260px,1fr);gap:20px;margin:0 36px;min-height:0}
.stage{background:#fafafa;border-radius:12px;min-height:0}
.viz{display:grid;grid-template-rows:1fr 1fr;gap:20px;min-height:0}
.card{position:relative;border-radius:12px;overflow:hidden;min-height:0}
.card h2{position:absolute;top:14px;left:18px;margin:0;font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:rgba(255,255,255,.8)}
.card .now{position:absolute;left:18px;right:18px;bottom:14px;font-size:16px;font-weight:600;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#sound{background:linear-gradient(90deg,#f07f7f,#d63636)}
#haptic{background:#0f172a}
canvas{display:block;width:100%;height:100%}
footer{padding:20px 36px 36px;max-width:900px;width:100%;margin:0 auto;text-align:center}
#where{font-size:12px;color:#8a8a8a;letter-spacing:.06em;text-transform:uppercase}
#where b{color:#111;font-weight:600}
#ticks{display:flex;gap:4px;justify-content:center;margin:14px 0 18px;min-height:3px}
#ticks i{width:22px;height:3px;border-radius:2px;background:#e6e6e6}
#ticks i.done{background:#a9c2f5}#ticks i.now{background:#2563eb}
#said{font-size:22px;line-height:1.45;color:#222;min-height:64px;margin:0;transition:opacity .8s}
@media(max-width:900px){body{grid-template-columns:1fr;grid-template-rows:auto auto auto auto}
  #log{grid-column:1;grid-row:auto;border-left:0;border-top:1px solid #eee}#lines{max-height:50vh}}
@media(max-width:800px){.split{grid-template-columns:1fr;grid-template-rows:minmax(320px,60vh) auto}.viz{grid-template-rows:200px 200px}}
@media(max-width:700px){header,footer{padding-left:18px;padding-right:18px}.split{margin:0 18px}#said{font-size:18px}}
@media(prefers-reduced-motion:reduce){#said{transition:none}}
</style></head><body>
<header><span id="address">Waiting for your iPhone…</span><span id="status" class="off">Connecting</span></header>
<main class="split">
<div class="stage"><canvas id="map" role="img" aria-label="Live floor plan with your position. The room and floor are written below it."></canvas></div>
<section class="viz" aria-label="What the phone is playing">
<div class="card" id="sound"><h2>Sound · AirPods</h2><canvas id="soundviz" aria-hidden="true"></canvas><div class="now" id="soundnow">Quiet</div></div>
<div class="card" id="haptic"><h2>Haptics · iPhone</h2><canvas id="hapticviz" aria-hidden="true"></canvas><div class="now" id="hapticnow">Still</div></div>
</section>
</main>
<footer><div id="where" aria-live="polite">Open House Tour on your iPhone</div><div id="ticks" aria-hidden="true"></div><p id="said" aria-live="polite"></p></footer>
<aside id="log"><h2>Transcript <a href="/transcript.txt" download>Download</a></h2><ol id="lines"></ol></aside>
<script>
const palette = { room: "#ffffff", wall: "#2b2b2b", window: "#bcd3f5", stairs: "#ededed", label: "#a3a3a3",
                  route: "rgba(37,99,235,.28)", stop: "rgba(37,99,235,.55)", trail: "rgba(37,99,235,.5)", you: "#2563eb" };
const cellColors = { "#": palette.wall, w: palette.window, s: palette.stairs, r: "#dcdcdc", v: "#dcdcdc" };
const surfaces = { hardwood: "Hardwood", carpet: "Carpet", tile: "Tile", concrete: "Concrete", deck: "Deck" };
let house, houseName, floors = [], trail = [], lastFloor = -1;
const canvas = document.getElementById("map"), ctx = canvas.getContext("2d");
const $ = id => document.getElementById(id);

// Only touch the DOM when text changes, so aria-live regions don't re-announce every poll.
function setText(el, text) { if (el.textContent !== text) el.textContent = text; }

function renderFloor(f) {
  const px = 8, c = document.createElement("canvas");
  c.width = f.cols * px; c.height = f.rows * px;
  const g = c.getContext("2d");
  for (let r = 0; r < f.rows; r++) for (let col = 0; col < f.cols; col++) {
    const i = r * f.cols + col;
    const fill = cellColors[f.cells[i]] || (f.rooms[i] !== "." ? palette.room : null);
    if (!fill) continue;
    g.fillStyle = fill; g.fillRect(col * px, r * px, px, px);
  }
  g.fillStyle = palette.label; g.font = "500 22px -apple-system, system-ui, sans-serif";
  g.textAlign = "center"; g.textBaseline = "middle";
  const ft = px / house.cellSize;
  for (const room of f.roomList) {
    if (room.kind === "closet") continue;
    const [x, y, w, h] = room.bounds;
    g.fillText(room.name, (x + w / 2) * ft, (y + h / 2) * ft);
  }
  return c;
}

function draw(s) {
  const img = floors[s.floor], box = canvas.getBoundingClientRect(), u = devicePixelRatio || 1;
  canvas.width = box.width * u; canvas.height = box.height * u;
  const scale = Math.min(canvas.width / img.width, canvas.height / img.height) * 0.9;
  const w = img.width * scale, h = img.height * scale, ox = (canvas.width - w) / 2, oy = (canvas.height - h) / 2;
  ctx.drawImage(img, ox, oy, w, h);
  const ft = w / house.width, at = (x, y) => [ox + x * ft, oy + y * ft];
  ctx.lineJoin = ctx.lineCap = "round";

  // The fixed route the avatar is locked to. It's house.tour, the same polyline
  // the app rails on, so this is the route itself and not a drawing of it. Shown
  // from page load, before anyone moves, so a tester can see where the path goes.
  const steps = house.tour.filter(p => p.floor === s.floor);
  ctx.strokeStyle = palette.route; ctx.lineWidth = 2 * u; ctx.setLineDash([6 * u, 6 * u]);
  ctx.beginPath(); steps.forEach((p, i) => ctx[i ? "lineTo" : "moveTo"](...at(p.x, p.y))); ctx.stroke();
  ctx.setLineDash([]); ctx.fillStyle = palette.stop;
  for (const p of steps) if (p.say) { ctx.beginPath(); ctx.arc(...at(p.x, p.y), 3 * u, 0, Math.PI * 2); ctx.fill(); }

  if (house.frontDoor.floor === s.floor) {
    const [dx, dy] = at(house.frontDoor.x, house.frontDoor.y);
    ctx.fillStyle = palette.you; ctx.fillRect(dx - 10 * u, dy - 2 * u, 20 * u, 4 * u);
  }
  ctx.strokeStyle = palette.trail; ctx.lineWidth = 3 * u;
  ctx.beginPath(); trail.forEach((p, i) => ctx[i ? "lineTo" : "moveTo"](...at(p.x, p.y))); ctx.stroke();

  // The avatar: a dot with a soft cone on the side it faces. Heading 0 is up the plan.
  const [cx, cy] = at(s.x, s.y), facing = s.heading - Math.PI / 2;
  ctx.fillStyle = palette.you; ctx.globalAlpha = 0.15;
  ctx.beginPath(); ctx.moveTo(cx, cy); ctx.arc(cx, cy, 34 * u, facing - 0.5, facing + 0.5); ctx.fill();
  ctx.globalAlpha = 1; ctx.strokeStyle = "#fff"; ctx.lineWidth = 2.5 * u;
  ctx.beginPath(); ctx.arc(cx, cy, 7 * u, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
}

// Which narrated stop the avatar is at or has just passed: the count of stops up
// to the nearest tour point on this floor.
function stopProgress(s) {
  let nearest = 0, best = Infinity;
  house.tour.forEach((p, i) => {
    const d = p.floor === s.floor ? Math.hypot(p.x - s.x, p.y - s.y) : Infinity;
    if (d < best) { best = d; nearest = i; }
  });
  const stops = house.tour.map((p, i) => p.say ? i : -1).filter(i => i >= 0);
  return { total: stops.length, current: Math.max(1, stops.filter(i => i <= nearest).length) };
}

function present(s) {
  const f = house.floors[s.floor], room = f.roomList.find(r => r.name === s.room);
  const size = room?.size ? room.size.map(Math.round).join(" × ") + " ft" : "";
  const where = $("where"), name = s.room || "Outside";
  const meta = [f.name, size, room && surfaces[room.floor]].filter(Boolean).join(" · ");
  if (where.dataset.key !== name + meta) {
    where.dataset.key = name + meta;
    where.replaceChildren(Object.assign(document.createElement("b"), { textContent: name }), " · " + meta);
  }
  setText($("address"), house.address);

  const progress = s.touring ? stopProgress(s) : null;
  const status = [progress ? `Stop ${progress.current} of ${progress.total}` : "Free explore",
                  s.onRail ? "" : "Off the path"].filter(Boolean).join(" · ");
  setText($("status"), status);
  $("status").className = "";
  const ticks = progress ? Array.from({ length: progress.total }, (_, i) =>
    `<i class="${i + 1 < progress.current ? "done" : i + 1 === progress.current ? "now" : ""}"></i>`).join("") : "";
  if ($("ticks").innerHTML !== ticks) $("ticks").innerHTML = ticks;

  setText($("said"), s.said);
  $("said").style.opacity = Date.now() / 1000 - s.saidAt < 8 ? 1 : 0.3;
}

async function poll() {
  try {
    const s = await (await fetch("/state", { cache: "no-store" })).json();
    if (s.house !== houseName) await loadHouse(s.house);
    if (s.floor !== lastFloor) { trail = []; lastFloor = s.floor; }
    const last = trail[trail.length - 1];
    if (!last || Math.hypot(last.x - s.x, last.y - s.y) > 0.3) trail.push({ x: s.x, y: s.y });
    if (trail.length > 600) trail.shift();
    present(s);
    draw(s);
    ingest(s);
  } catch (e) {
    setText($("status"), "Disconnected. Is the app open?");
    $("status").className = "off";
  }
  setTimeout(poll, 100);
}

// The phone can switch houses; `name` is the one /state says is loaded.
async function loadHouse(name) {
  house = await (await fetch("/house.json", { cache: "no-store" })).json();
  floors = house.floors.map(renderFloor);
  houseName = name;
  trail = [];
  lastFloor = -1;
}

// The transcript only grows, so fetch what's after the last line shown.
let lastLine = -1;
const whoLabel = { you: "You", app: "App", skipped: "Skipped, app was talking", event: "Event" };
async function pollTranscript() {
  try {
    const entries = await (await fetch(`/transcript?after=${lastLine}`, { cache: "no-store" })).json();
    const list = $("lines"), atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
    for (const e of entries) {
      const li = document.createElement("li"), meta = document.createElement("div"), text = document.createElement("div");
      li.className = e.who;
      meta.className = "meta";
      const time = new Date(e.time * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      meta.append(Object.assign(document.createElement("b"), { textContent: whoLabel[e.who] || e.who }), ` · ${time} · ${e.place}`);
      text.textContent = e.text;
      li.append(meta, text);
      list.append(li);
      lastLine = e.id;
    }
    if (entries.length && atBottom) list.scrollTop = list.scrollHeight;
  } catch (e) {}
  setTimeout(pollTranscript, 500);
}

// The visualizer panel. Phone and laptop clocks differ, so everything animates
// from the moment this page first sees it, not from the phone's timestamps.
const soundCv = $("soundviz"), soundCtx = soundCv.getContext("2d");
const hapticCv = $("hapticviz"), hapticCtx = hapticCv.getContext("2d");
const BARS = 72, sounds = [], rings = [];
const ears = [{ name: "L", bars: new Array(BARS).fill(0.03), level: 0 },
              { name: "R", bars: new Array(BARS).fill(0.03), level: 0 }];
let lastEvent = 0, primed = false, lastSaid = 0, speechUntil = 0, glow = 0;
let speaking = false, sawSpeaking = false, measured = [0, 0];

function ingest(s) {
  const now = performance.now();
  // Real per-ear output, measured on the phone. Square root because loudness
  // is heard roughly that way, so quiet sounds still show.
  measured = [Math.min(1, Math.sqrt(s.left || 0) * 2.2), Math.min(1, Math.sqrt(s.right || 0) * 2.2)];
  if (s.speaking) sawSpeaking = true;
  speaking = !!s.speaking;
  if (s.saidAt !== lastSaid) {
    // Speech has no end signal here, so its length is estimated from the words.
    if (primed && s.said) { speechUntil = now + Math.min(12000, 700 + s.said.length * 62); setText($("soundnow"), "Voice"); }
    lastSaid = s.saidAt;
  }
  for (const e of s.events || []) {
    if (e.id <= lastEvent) continue;
    lastEvent = e.id;
    if (!primed) continue;   // don't replay whatever happened before the page opened
    if (e.kind === "haptic") { rings.push({ born: now, level: e.level }); glow = Math.max(glow, e.level); setText($("hapticnow"), e.name); }
    else { sounds.push({ born: now, level: e.level, pan: e.pan || 0 }); setText($("soundnow"), e.name); }
  }
  primed = true;
}

function fit(cv) {
  const b = cv.getBoundingClientRect(), u = devicePixelRatio || 1;
  const w = Math.round(b.width * u), h = Math.round(b.height * u);
  if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
  return u;
}

function frame(t) {
  // Sound: one row of white bars per ear, L above R. Each row follows that
  // ear's measured level, so the 3D front door beacon leans to one side as you
  // turn. Speech and the one-shot effects are mono, the same in both ears.
  const talking = sawSpeaking ? speaking : t < speechUntil;
  const voice = talking ? 0.5 + 0.4 * Math.abs(Math.sin(t / 110)) : 0, side = [voice, voice];
  if (!talking && $("soundnow").textContent === "Voice") setText($("soundnow"), "Quiet");
  // A one-shot lights the ear it played in: a turn tick is panned to one side.
  for (let i = sounds.length - 1; i >= 0; i--) {
    const age = (t - sounds[i].born) / 1000;
    if (age > 1) { sounds.splice(i, 1); continue; }
    const e = sounds[i].level * Math.exp(-age * 3.5), pan = sounds[i].pan;
    side[0] = Math.max(side[0], e * (pan > 0 ? 1 - pan : 1));
    side[1] = Math.max(side[1], e * (pan < 0 ? 1 + pan : 1));
  }
  const u = fit(soundCv), W = soundCv.width, H = soundCv.height;
  const top = 40 * u, rowH = (H - top - 44 * u) / 2;
  soundCtx.clearRect(0, 0, W, H);
  ears.forEach((ear, e) => {
    ear.level += (measured[e] - ear.level) * 0.25;
    const energy = Math.max(side[e], ear.level), mid = top + rowH * (e + 0.5);
    soundCtx.fillStyle = "rgba(255,255,255,.75)"; soundCtx.font = `600 ${11 * u}px -apple-system, system-ui, sans-serif`;
    soundCtx.textBaseline = "middle"; soundCtx.fillText(ear.name, 18 * u, mid);
    soundCtx.fillStyle = "#fff";
    const x0 = 40 * u, span = W - x0 - 18 * u, g = span / BARS, w = Math.max(1.5 * u, g * 0.3);
    for (let i = 0; i < BARS; i++) {
      const taper = Math.sin(Math.PI * (0.06 + 0.88 * i / (BARS - 1)));
      const target = 0.025 + energy * taper * (0.3 + 0.7 * Math.random());
      ear.bars[i] += (target - ear.bars[i]) * (target > ear.bars[i] ? 0.55 : 0.15);
      const h = Math.max(2 * u, ear.bars[i] * rowH * 0.9);
      soundCtx.fillRect(x0 + i * g + (g - w) / 2, mid - h / 2, w, h);
    }
  });

  // Haptics: a circle that sends out a ring for every vibration, wider and
  // brighter the stronger it was.
  const v = fit(hapticCv), HW = hapticCv.width, HH = hapticCv.height;
  const cx = HW / 2, cy = HH / 2, r0 = Math.min(HW, HH) * 0.1, rMax = Math.min(HW, HH) * 0.45;
  hapticCtx.clearRect(0, 0, HW, HH);
  for (let i = rings.length - 1; i >= 0; i--) {
    const age = (t - rings[i].born) / 1100;
    if (age >= 1) { rings.splice(i, 1); continue; }
    const level = rings[i].level, r = r0 + (rMax - r0) * (1 - (1 - age) * (1 - age));
    hapticCtx.strokeStyle = `rgba(125,170,255,${(1 - age) * (0.3 + 0.7 * level)})`;
    hapticCtx.lineWidth = (1.5 + 6 * level) * v * (1 - 0.6 * age);
    hapticCtx.beginPath(); hapticCtx.arc(cx, cy, r, 0, Math.PI * 2); hapticCtx.stroke();
  }
  glow *= 0.9;
  hapticCtx.fillStyle = `rgba(125,170,255,${0.3 + 0.7 * glow})`;
  hapticCtx.beginPath(); hapticCtx.arc(cx, cy, r0 * (1 + 0.3 * glow), 0, Math.PI * 2); hapticCtx.fill();
  requestAnimationFrame(frame);
}

requestAnimationFrame(frame);
poll();
pollTranscript();
</script></body></html>
"""#
