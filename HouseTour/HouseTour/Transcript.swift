import Foundation

/// A running log of the conversation between the user and the app, for testing:
/// what was asked and tapped, what the app said back, and what it skipped
/// because it was already talking. Each app launch writes its own text file to
/// Documents/Transcripts (visible in the Files app), and the laptop viewer
/// shows it live.
final class Transcript {
    struct Entry: Encodable {
        let id: Int
        let time: Double   // seconds since 1970
        let who: String    // "you", "app", "skipped", or "event" (silent things, like bumping a wall)
        let text: String
        let place: String  // where the avatar was, "Kitchen, First floor"
    }

    private let lock = NSLock()
    private var entries: [Entry] = []   // guarded by `lock`; read from the viewer's queue
    private let file: FileHandle?
    let fileName: String

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        fileName = "House Tour \(stamp.string(from: Date())).txt"
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    deinit { try? file?.close() }

    func add(_ who: String, _ text: String, place: String) {
        let now = Date()
        lock.lock()
        let entry = Entry(id: entries.count, time: now.timeIntervalSince1970, who: who, text: text, place: place)
        entries.append(entry)
        lock.unlock()
        file?.write(Data((Self.line(entry) + "\n").utf8))
    }

    /// Entries after `id`, so the viewer only fetches what's new. An `id` past
    /// the end is from a page left open across an app relaunch: it gets everything.
    func entries(after id: Int) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard id < entries.count else { return entries }
        return Array(entries.dropFirst(max(0, id + 1)))
    }

    /// The whole session as plain text, one entry per line.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(Self.line).joined(separator: "\n") + "\n"
    }

    /// "14:05:22  YOU      [Kitchen, First floor]  Asked "where am I" (where am I)"
    private static func line(_ e: Entry) -> String {
        let who = e.who.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(clock.string(from: Date(timeIntervalSince1970: e.time)))  \(who) [\(e.place)]  \(e.text)"
    }
}
