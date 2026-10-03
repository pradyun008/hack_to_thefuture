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
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>House Tour · Live viewer</title><style>@import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=Manrope:wght@400;500;600;700;800&display=swap');
:root{--ink:#233b37;--muted:#6b7974;--green:#246d57;--line:#e3e7df;--paper:#f6f7f2}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:14px 'DM Sans',system-ui,sans-serif}button,select{font:inherit}button,a,select,input{touch-action:manipulation}button{cursor:pointer}button{color:inherit}button:focus-visible,a:focus-visible,select:focus-visible,canvas:focus-visible,input:focus-visible{outline:3px solid #b36c24;outline-offset:4px}.skip{position:fixed;top:-60px;z-index:10;background:white;padding:15px}.skip:focus{top:10px}.rail{position:fixed;inset:0 auto 0 0;width:244px;background:#193d35;color:#cbd9d2;padding:35px 22px;display:flex;flex-direction:column}.brand{color:white;text-decoration:none;font:800 26px Manrope,system-ui;letter-spacing:-1px;position:relative;margin-bottom:57px}.brand>span:not(.brand-icon){font-weight:400;color:#b8d8c7}.brand-icon{display:inline-grid;place-items:center;width:34px;height:34px;border:1px solid #81ad96;border-radius:10px;margin-right:7px;font-size:28px}.brand small{display:block;font:9px 'DM Sans',sans-serif;letter-spacing:2.1px;margin:12px 0 0 44px;color:#a9c4b6}.nav-label{font-size:9px;font-weight:700;letter-spacing:1.6px;color:#9cb5a9;margin:0 13px 14px;display:flex;justify-content:space-between}.nav{width:100%;background:none;border:0;border-radius:9px;color:#c0d2c8;text-align:left;padding:14px 13px;display:flex;align-items:center;gap:13px;margin-bottom:4px}.nav.active{background:#31554a;color:white}.nav>span:first-child{font-size:19px;width:20px}.nav-dot{width:5px;height:5px;border-radius:50%;background:#c3ddb9;margin-left:auto}.rail-divider{height:1px;background:#416154;margin:26px 11px}.room-button{width:100%;border:0;background:none;color:#c5d6cc;text-align:left;padding:10px 13px;font-size:12px;border-radius:7px;display:flex;gap:12px;align-items:center}.room-button::before{content:'';width:5px;height:5px;border:1px solid #87a997;border-radius:50%}.room-button.selected{background:#284c40;color:#fff}.room-button.selected::before{background:#c9dfb9}#rooms{overflow:auto;max-height:38vh}.rail-bottom{margin-top:auto;padding:28px 12px 0}.access-icon{display:block;color:#aac7b0;font-size:29px;margin-bottom:12px}.rail-bottom strong{font-size:12px;color:#e0e9df}.rail-bottom p{font-size:11px;line-height:1.9;color:#a8c1b3}.prototype{display:block;font-size:8px;letter-spacing:1.2px;margin-top:25px;color:#a8c1b3}.workspace{margin-left:244px}header{height:77px;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 40px;background:#fcfcf9}.breadcrumb{font-size:12px;color:var(--muted)}.breadcrumb span{margin:0 17px;color:#9da99e}.breadcrumb strong{font-weight:500;color:var(--ink)}.connection{border:1px solid #dce4d9;background:#fff;border-radius:25px;padding:10px 15px;font-size:11px;display:flex;align-items:center;gap:9px}.dot{width:7px;height:7px;background:#ad7c3c;border-radius:50%}main{max-width:1550px;margin:auto;padding:35px 40px 18px}.title-row{display:flex;justify-content:space-between;align-items:center;margin-bottom:29px}.eyebrow{font-size:9px;font-weight:700;letter-spacing:1.65px;color:var(--muted);display:flex;align-items:center;gap:7px}h1{font:600 34px Manrope,system-ui;letter-spacing:-1.3px;margin:10px 0}.title-row p{color:var(--muted);font-size:12px;margin:0}.house-select label{display:block;font-size:8px;letter-spacing:1.3px;color:var(--muted);margin-bottom:9px}.house-select select{background:white;padding:10px 30px 10px 12px;border:1px solid var(--line);border-radius:7px;font-size:11px}.tour-layout{display:grid;grid-template-columns:minmax(0,1fr) 270px;gap:22px}.map-card{background:white;border:1px solid var(--line);border-radius:13px;overflow:hidden;min-width:0}.map-toolbar{height:64px;display:flex;justify-content:space-between;align-items:center;padding:0 20px;border-bottom:1px solid var(--line);gap:10px}.map-toolbar>div:first-child{display:flex;align-items:center;gap:9px}h2{font:700 13px Manrope,system-ui;margin:0}.live-dot{width:6px;height:6px;border-radius:50%;background:#438365;display:inline-block}.badge{font-size:9px;padding:5px 8px;border-radius:5px;background:#edf3e9;color:#456744}.segmented{display:flex;padding:3px;background:#f1f3ee;border-radius:6px;gap:3px}.segmented button{border:0;background:none;border-radius:4px;font-size:9px;padding:7px 10px;color:var(--muted)}.segmented button.selected{background:white;color:var(--ink);box-shadow:0 1px 4px #0001}.map-wrap{height:505px;position:relative;background-color:#fafbf7;background-image:radial-gradient(#d9dfd4 .7px,transparent .7px);background-size:15px 15px;overflow:hidden}canvas{width:100%;height:100%;display:block}.map-note{position:absolute;top:21px;left:22px;font-size:8px;letter-spacing:1.3px;color:#7c877d;pointer-events:none}.map-note span{margin-left:5px}.compass{position:absolute;right:25px;top:25px;text-align:center;font-size:11px;color:#7b887d;line-height:1.8}.map-controls{position:absolute;right:18px;bottom:53px;display:grid;border-radius:8px;overflow:hidden;box-shadow:0 3px 12px #203b3710;border:1px solid var(--line)}.map-controls button{background:white;border:0;border-bottom:1px solid var(--line);width:32px;height:32px;font-size:17px}.map-controls button:last-child{border-bottom:0}.map-footnote{position:absolute;bottom:18px;left:22px;right:22px;display:flex;gap:18px;font-size:9px;color:#68776c}.map-footnote span:last-child{margin-left:auto}.legend{display:flex;align-items:center;gap:18px;min-height:51px;padding:12px 20px;font-size:9px;color:var(--muted);border-top:1px solid var(--line);flex-wrap:wrap}.legend span{display:flex;gap:7px;align-items:center}.legend i{display:inline-block}.legend-you{width:8px;height:8px;border-radius:50%;background:var(--green)}.legend-path{width:16px;border-top:2px dashed #96ad8d}.legend-door{width:10px;height:5px;background:#bb8949}.legend label{margin-left:auto;display:flex;align-items:center;gap:5px}input{accent-color:var(--green)}.details{display:flex;flex-direction:column;gap:16px}.location-card{position:relative;background:#edf2e8;border:1px solid #dce6d4;border-radius:12px;padding:22px 18px}.location-card h2{font-size:23px;margin:13px 0 5px;letter-spacing:-.5px}.location-card>p{font-size:10px;color:#687863;margin:0}.location-icon{position:absolute;right:18px;top:51px;font-size:23px;color:#719164}.metrics{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:21px 0}.metrics small{display:block;font-size:8px;letter-spacing:1px;color:#65775f;margin-bottom:7px}.metrics strong{font-size:12px;font-weight:500}.outline{width:100%;border:1px solid #bfceb6;border-radius:6px;padding:10px;background:transparent;font-size:10px}.nearby-card{border:1px solid var(--line);background:#fff;border-radius:12px;padding:17px 18px}.section-heading{display:flex;justify-content:space-between;margin-bottom:9px}.section-heading>span{color:#8b9d86}.nearby-item{display:flex;gap:11px;align-items:center;padding:13px 0;border-bottom:1px solid #edf0e9}.nearby-item:last-child{border:0}.nearby-symbol{width:29px;height:29px;display:grid;place-items:center;background:#f4f5ef;border-radius:7px;color:#768a6c;font-size:16px}.nearby-item strong{display:block;font-size:11px;font-weight:500}.nearby-item small{display:block;font-size:9px;color:var(--muted);margin-top:4px}.guide-card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:17px 18px;flex:1}.guide-icon{font-size:23px;color:#798f68;float:right}.guide-card h2{margin:3px 0 9px}.guide-card p{font-size:11px;color:var(--muted);line-height:1.7;margin:0 0 16px;max-width:190px}.primary{width:100%;padding:12px;background:var(--green);color:white;border:0;border-radius:7px;font-size:11px;display:flex;justify-content:space-between}.narration{display:flex;align-items:center;gap:17px;background:white;border:1px solid var(--line);border-radius:12px;padding:19px 21px;margin-top:21px;min-height:92px}.audio-icon{background:#edf2e8;color:#57764a;border-radius:10px;width:44px;height:44px;display:grid;place-items:center;font-size:12px;flex-shrink:0}.narration-copy{flex:1}.narration .eyebrow{font-size:8px}.narration .eyebrow span{font-size:7px;background:#f2f4ee;padding:3px 5px;letter-spacing:.5px}.narration p{margin:8px 0 0;font-size:12px;line-height:1.7}.round{width:33px;height:33px;border:1px solid var(--line);border-radius:50%;background:white;font-size:19px}.sound-toggle{background:none;border:1px solid var(--line);border-radius:6px;padding:9px;font-size:10px}footer{display:flex;justify-content:space-between;font-size:9px;color:#778575;margin-top:22px}dialog{border:1px solid var(--line);border-radius:16px;padding:35px;max-width:530px;width:90%;color:var(--ink);box-shadow:0 20px 80px #10251c33}dialog::backdrop{background:#10251c66}dialog h2{font-size:22px;margin-bottom:17px}dialog p,dialog li{line-height:1.8;color:var(--muted);font-size:13px}.dialog-close{position:absolute;right:12px;top:10px;border:0;background:none;font-size:24px}.dialog-info{background:#edf2e8;border-radius:9px;padding:16px;margin:18px 0}.dialog-room{padding:10px 0;border-bottom:1px solid var(--line)}@media(min-width:1500px){.map-wrap{height:590px}}@media(max-width:1150px){.rail{width:205px;padding:30px 15px}.workspace{margin-left:205px}main{padding:25px}header{padding:0 25px}.tour-layout{grid-template-columns:minmax(0,1fr) 240px;gap:15px}.map-toolbar{padding:0 12px}.badge{display:none}}@media(max-width:850px){.rail{position:static;width:auto;padding:17px 22px;display:block}.brand{margin:0;display:block}.brand small,.rail .nav-label,.rail .nav,.rail-divider,#rooms,.rail-bottom{display:none}.workspace{margin:0}header{height:65px;padding:0 20px}.tour-layout{grid-template-columns:1fr}.details{display:grid;grid-template-columns:1fr 1fr}.guide-card{grid-column:1/-1}.title-row{gap:15px}h1{font-size:27px}.map-wrap{height:480px}}@media(max-width:520px){main{padding:23px 15px}.breadcrumb{font-size:10px}.connection{font-size:9px;padding:8px}.title-row{display:block}.house-select{margin-top:18px}.details{display:flex}.narration{flex-wrap:wrap}.narration-copy{min-width:70%}.map-footnote{gap:8px;font-size:8px}.map-footnote span:last-child{display:none}footer{gap:20px}.map-toolbar h2{font-size:11px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
</style><style>
.map-wrap{height:505px;display:flex;align-items:center;justify-content:center}#map{width:100%;height:100%;object-fit:contain}.viewer-room{padding:10px 13px;font-size:12px;color:#c5d6cc}.viewer-room.selected{background:#31554a;border-radius:7px;color:white}.viewer-note{font-size:11px;color:var(--muted);line-height:1.8}.connection{cursor:default}#room{font-size:23px;overflow-wrap:anywhere}#said{transition:opacity 1s}#status:empty::after{content:'Free explore'}.rail-bottom{padding-top:15px}.map-footnote{justify-content:center}.nav-static{padding:14px 13px;background:#31554a;border-radius:9px;color:white;margin-bottom:24px}.location-card{min-height:190px}.details .guide-card{flex:0}.nearby-card{flex:1}.map-toolbar #floor{font-size:11px;color:var(--muted)}@media(prefers-reduced-motion:reduce){#said{transition:none}}@media(min-width:1500px){.map-wrap{height:590px}}
</style></head><body>
<a class="skip" href="#main">Skip to live tour</a>
<aside class="rail"><div class="brand"><span class="brand-icon">⌂</span> house<span>tour</span><small>SPACE FOR EVERYONE</small></div><div class="nav-label">YOUR WORKSPACE</div><div class="nav-static">▦ &nbsp; Live house tour</div><div class="nav-label">ROOMS ON THIS FLOOR</div><div id="rooms"></div><div class="rail-bottom"><span class="access-icon">◎</span><strong>A different way to see.</strong><p>Explore through sound,<br>touch, and your own curiosity.</p><span class="prototype">IPHONE COMPANION VIEWER</span></div></aside>
<div class="workspace"><header><span class="breadcrumb">Your homes <span>/</span> <strong>Live tour</strong></span><span class="connection"><span class="live-dot"></span> iPhone companion</span></header>
<main id="main" tabindex="-1"><div class="title-row"><div><div class="eyebrow">EXPLORE AT YOUR OWN PACE</div><h1>A place to call home.</h1><p id="address">Waiting for your iPhone…</p></div><div class="house-select"><div class="eyebrow">CONTROLLED FROM YOUR IPHONE</div></div></div>
<div class="tour-layout"><section class="map-card" aria-labelledby="mapTitle"><div class="map-toolbar"><div><span class="live-dot"></span><h2 id="mapTitle">Your exploration</h2><span id="status" class="badge"></span></div><span id="floor"></span></div><div class="map-wrap"><div class="map-note">LIVE FLOOR PLAN</div><canvas id="map" aria-label="Live floorplan and position from the iPhone. The current room and floor are provided as text beside the map."></canvas><div class="map-footnote">Move on your iPhone. Follow your exploration here.</div></div><div class="legend"><span><i style="width:8px;height:8px;border-radius:50%;background:#e74c3c"></i>Your position</span><span><i style="width:16px;border-top:2px solid #e74c3c80"></i>Exploration path</span><span><i style="width:10px;height:5px;background:#2ecc71"></i>Entrance</span></div></section>
<aside class="details"><section class="location-card"><div class="eyebrow"><span class="live-dot"></span> YOU ARE HERE</div><h2 id="room">Connecting...</h2><p id="roomMeta">Location comes directly from your phone.</p><div class="metrics"><div><small>ROOM SIZE</small><strong id="roomSize">—</strong></div><div><small>FLOOR SURFACE</small><strong id="surface">—</strong></div></div></section><section class="nearby-card"><div class="section-heading"><h2>House at a glance</h2><span>⌂</span></div><p id="summary" class="viewer-note">Open House Tour on your iPhone to begin.</p><p class="viewer-note">The floor, position, tour status, and narration follow your iPhone automatically.</p></section><section class="guide-card"><span class="guide-icon">✧</span><h2>You set the pace.</h2><p>Use the guided tour or explore freely with your iPhone. This screen follows along.</p></section></aside></div>
<section class="narration" aria-labelledby="narrationTitle"><div class="audio-icon" aria-hidden="true">▂ ▅ ▇ ▅ ▂</div><div class="narration-copy"><div class="eyebrow" id="narrationTitle">LIVE NARRATION <span>FROM YOUR IPHONE</span></div><p id="said"></p></div></section><footer><span>Designed for independent exploration.</span><span>Sound + touch. A home, understood.</span></footer>
</main></div><script>
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
</script><script>
// Display-only additions. Never changes state, movement, polling, or audio.
const surfaces = {hardwood:'Hardwood',carpet:'Carpet',tile:'Tile',concrete:'Concrete',deck:'Deck boards',unknown:'Not listed'};
function updatePresentation() {
  if (!house || lastFloor < 0) return;
  document.getElementById('address').textContent = house.address;
  document.getElementById('summary').textContent = house.summary;
  const f = house.floors[lastFloor];
  const name = document.getElementById('room').textContent;
  const room = f.roomList.find(r => r.name === name);
  document.getElementById('roomMeta').textContent = room ? f.name : 'Location comes directly from your phone.';
  document.getElementById('roomSize').textContent = room?.size ? room.size.map(v => Math.round(v*10)/10).join(' × ')+' ft' : 'Not listed';
  document.getElementById('surface').textContent = room ? surfaces[room.floor] : '—';
  const list = document.getElementById('rooms');
  list.replaceChildren();
  for (const r of f.roomList) {
    if (r.kind === 'closet') continue;
    const item = document.createElement('div');
    item.className = 'viewer-room' + (r === room ? ' selected' : '');
    item.textContent = r.name;
    if (r === room) item.setAttribute('aria-current','location');
    list.append(item);
  }
}
new MutationObserver(updatePresentation).observe(document.getElementById('room'), {childList:true});

</script></body></html>

"""#
