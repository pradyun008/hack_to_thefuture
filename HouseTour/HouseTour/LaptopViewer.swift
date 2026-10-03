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
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "laptop-viewer")
    private let lock = NSLock()
    private var snapshot = Snapshot()
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
header,.stage,footer{grid-column:1}
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
.stage{margin:0 36px;background:#fafafa;border-radius:12px;min-height:0}
canvas{display:block;width:100%;height:100%}
footer{padding:20px 36px 36px;max-width:900px;width:100%;margin:0 auto;text-align:center}
#where{font-size:12px;color:#8a8a8a;letter-spacing:.06em;text-transform:uppercase}
#where b{color:#111;font-weight:600}
#ticks{display:flex;gap:4px;justify-content:center;margin:14px 0 18px;min-height:3px}
#ticks i{width:22px;height:3px;border-radius:2px;background:#e6e6e6}
#ticks i.done{background:#a9c2f5}#ticks i.now{background:#2563eb}
#said{font-size:22px;line-height:1.45;color:#222;min-height:64px;margin:0;transition:opacity .8s}
@media(max-width:900px){body{grid-template-columns:1fr;grid-template-rows:auto 60vh auto auto}
  #log{grid-column:1;grid-row:auto;border-left:0;border-top:1px solid #eee}#lines{max-height:50vh}}
@media(max-width:700px){header,footer{padding-left:18px;padding-right:18px}.stage{margin:0 18px}#said{font-size:18px}}
@media(prefers-reduced-motion:reduce){#said{transition:none}}
</style></head><body>
<header><span id="address">Waiting for your iPhone…</span><span id="status" class="off">Connecting</span></header>
<div class="stage"><canvas id="map" role="img" aria-label="Live floor plan with your position. The room and floor are written below it."></canvas></div>
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

poll();
pollTranscript();
</script></body></html>
"""#
