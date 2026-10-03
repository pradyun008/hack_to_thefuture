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
            // "GET /state HTTP/1.1" -> "/state"
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let (body, type): (Data, String)
            switch path {
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
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
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
<html><head><meta charset="utf-8"><title>House Tour viewer</title>
<style>
  body { margin: 0; font-family: -apple-system, system-ui, sans-serif; background: #111; color: #eee; }
  header { display: flex; gap: 24px; align-items: baseline; padding: 12px 20px; }
  #room { font-size: 28px; font-weight: 700; }
  #floor, #status { color: #aaa; font-size: 18px; }
  #said { font-size: 22px; color: #ffd166; min-height: 28px; padding: 0 20px 8px; transition: opacity 1s; }
  canvas { display: block; margin: 0 auto; }
</style></head>
<body>
<header><span id="room">Connecting...</span><span id="floor"></span><span id="status"></span></header>
<div id="said"></div>
<canvas id="map"></canvas>
<script>
const colors = { hardwood: "#eecc9e", carpet: "#d6d6f2", tile: "#bde3f2", concrete: "#d1d1d1",
                 deck: "#ccb294", unknown: "#f7f2d9" };
const cellColors = { "#": "#000", w: "#2f7bf5", s: "#2aa8a8", r: "#f59a23", v: "#999" };
let house, houseName, floors = [], trail = [], lastFloor = -1;
const canvas = document.getElementById("map"), ctx = canvas.getContext("2d");

function renderFloor(f) {
  const px = 8, c = document.createElement("canvas");
  c.width = f.cols * px; c.height = f.rows * px;
  const g = c.getContext("2d");
  g.fillStyle = "#222"; g.fillRect(0, 0, c.width, c.height);
  for (let r = 0; r < f.rows; r++) for (let col = 0; col < f.cols; col++) {
    const i = r * f.cols + col, k = f.cells[i], room = f.rooms[i];
    let fill = cellColors[k];
    if (!fill && room !== ".") fill = colors[f.roomList[room.charCodeAt(0) - 65].floor];
    if (!fill) continue;
    g.fillStyle = fill; g.fillRect(col * px, r * px, px, px);
  }
  g.fillStyle = "#222"; g.font = "bold 26px -apple-system, sans-serif"; g.textAlign = "center";
  const ft = px / house.cellSize;
  for (const room of f.roomList) {
    if (room.kind === "closet") continue;
    const [x, y, w, h] = room.bounds;
    g.fillText(room.name, (x + w / 2) * ft, (y + h / 2) * ft);
  }
  return c;
}

function draw(s) {
  const img = floors[s.floor];
  const scale = Math.min(innerWidth / img.width, (innerHeight - 110) / img.height);
  canvas.width = img.width * scale; canvas.height = img.height * scale;
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
  const ft = canvas.width / house.width;
  if (house.frontDoor.floor === s.floor) {
    ctx.fillStyle = "#2ecc71";
    ctx.fillRect(house.frontDoor.x * ft - 18, house.frontDoor.y * ft - 7, 36, 14);
  }
  drawRoute(s.floor, ft);
  ctx.strokeStyle = "rgba(231, 76, 60, 0.5)"; ctx.lineWidth = 4; ctx.beginPath();
  trail.forEach((p, i) => i ? ctx.lineTo(p.x * ft, p.y * ft) : ctx.moveTo(p.x * ft, p.y * ft));
  ctx.stroke();
  // The avatar: a body circle with a pointed head on the side it faces.
  const cx = s.x * ft, cy = s.y * ft, ax = Math.sin(s.heading), ay = -Math.cos(s.heading);
  const at = (f, a) => [cx + ax * f - ay * a, cy + ay * f + ax * a];
  ctx.fillStyle = "#e74c3c"; ctx.strokeStyle = "#fff"; ctx.lineWidth = 3;
  ctx.beginPath(); ctx.arc(cx, cy, 11, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(...at(24, 0)); ctx.lineTo(...at(8, 9)); ctx.lineTo(...at(8, -9)); ctx.closePath();
  ctx.lineJoin = "round"; ctx.fill(); ctx.stroke();
}

// The fixed route the avatar is locked to. It's house.tour, the same polyline
// the app rails on, so this is the route itself and not a drawing of it. Shown
// from page load, before anyone moves, so a tester can see where the path goes.
function drawRoute(floor, ft) {
  const steps = house.tour.filter(p => p.floor === floor);
  if (steps.length < 2) return;
  ctx.save();
  ctx.strokeStyle = "rgba(46, 134, 222, 0.85)";
  ctx.lineWidth = 6;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.setLineDash([14, 9]);
  ctx.beginPath();
  steps.forEach((p, i) => i ? ctx.lineTo(p.x * ft, p.y * ft) : ctx.moveTo(p.x * ft, p.y * ft));
  ctx.stroke();
  ctx.setLineDash([]);
  // Narrated stops sit a little larger than the plain corners.
  for (const p of steps) {
    ctx.beginPath();
    ctx.arc(p.x * ft, p.y * ft, p.say ? 7 : 3.5, 0, Math.PI * 2);
    ctx.fillStyle = p.say ? "#2e86de" : "rgba(46, 134, 222, 0.6)";
    ctx.fill();
    if (p.say) { ctx.strokeStyle = "#fff"; ctx.lineWidth = 2; ctx.stroke(); }
  }
  ctx.restore();
}

async function poll() {
  try {
    const s = await (await fetch("/state", { cache: "no-store" })).json();
    if (s.house !== houseName) await loadHouse(s.house);
    if (s.floor !== lastFloor) { trail = []; lastFloor = s.floor; }
    const last = trail[trail.length - 1];
    if (!last || Math.hypot(last.x - s.x, last.y - s.y) > 0.3) trail.push({ x: s.x, y: s.y });
    if (trail.length > 600) trail.shift();
    document.getElementById("room").textContent = s.room || "Outside";
    document.getElementById("floor").textContent = house.floors[s.floor].name;
    document.getElementById("status").textContent =
      [s.touring ? "Guided tour" : "", s.onRail ? "On the path" : "Off the path"]
        .filter(Boolean).join(" \u00b7 ");
    const said = document.getElementById("said");
    said.textContent = s.said ? '"' + s.said + '"' : "";
    said.style.opacity = Date.now() / 1000 - s.saidAt < 6 ? 1 : 0.25;
    draw(s);
  } catch (e) {
    document.getElementById("room").textContent = "Disconnected. Is the app open?";
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

poll();
</script></body></html>
"""#
