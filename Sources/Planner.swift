import SwiftUI
import AppKit
import WebKit

// MARK: - The planner, inside Murmur
//
// The Weekly Planner page (Resources/Planner.html) runs in a Murmur window. On claude.ai it saved to
// your account through `window.claude`; here a small stand-in for `window.claude` saves the same data
// to planner.json on this Mac instead. The Today tab in the island reads and writes that same file,
// so ticking a task off in either place shows up in the other.

/// The planner's saved data, shared by the planner window and the island
@MainActor
final class PlannerStore: ObservableObject {
    static let shared = PlannerStore()

    /// The planner's whole state, kept as plain JSON so nothing the page adds is ever lost
    private(set) var state: [String: Any] = [:]
    /// Bumped whenever the data changes, so views redraw
    @Published private(set) var version = 0

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("planner.json")
    }

    private init() { load() }

    var hasData: Bool { state["v"] != nil }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        state = obj
        version += 1
    }

    /// From the planner page (it saves the whole state each time)
    func replace(with json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        state = obj
        try? data.write(to: Self.fileURL, options: .atomic)
        version += 1
    }

    var rawJSON: String? {
        guard hasData, let data = try? JSONSerialization.data(withJSONObject: state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// From the island: save, and tell an open planner window to pick it up
    private func commit() {
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        version += 1
        PlannerWindow.shared.refreshPage()
    }

    // MARK: Reading, with the planner's own rules

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let urgency: Int
        let done: Bool
        let colour: Color?
        let subject: String?
        let steps: (done: Int, total: Int)
        let repeats: Bool

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.title == b.title && a.urgency == b.urgency && a.done == b.done
                && a.steps.done == b.steps.done && a.steps.total == b.steps.total
        }
    }

    struct Exam: Identifiable {
        let id: String
        let subject: String
        let colour: Color?
        let days: Int
        let period: String
    }

    static func dayString(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private var tasks: [[String: Any]] { state["tasks"] as? [[String: Any]] ?? [] }
    private var subjects: [[String: Any]] { state["subjects"] as? [[String: Any]] ?? [] }

    private func subject(_ id: Any?) -> (name: String, colour: Color?)? {
        guard let id = id as? String, let s = subjects.first(where: { $0["id"] as? String == id }) else { return nil }
        return (s["name"] as? String ?? "", (s["c"] as? String).flatMap(Color.init(hex:)))
    }

    /// Same as the page: a one-off task on its day, or a repeating one from its start date on
    private func occurs(_ t: [String: Any], on d: String) -> Bool {
        let rep = t["rep"] as? String ?? "none"
        guard let date = t["date"] as? String else { return false }
        if rep == "none" { return date == d }
        if d < date || (t["skip"] as? [String: Any])?[d] != nil { return false }
        if rep == "daily" { return true }
        return Self.daysBetween(date, d) % 7 == 0
    }

    private func isDone(_ t: [String: Any], on d: String) -> Bool {
        if (t["rep"] as? String ?? "none") == "none" { return t["done"] as? Bool ?? false }
        return ((t["doneOn"] as? [String: Any])?[d] as? Bool) ?? false
    }

    private static func daysBetween(_ a: String, _ b: String) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let x = f.date(from: a), let y = f.date(from: b) else { return 0 }
        return Int((y.timeIntervalSince(x) / 86400).rounded())
    }

    /// Today's tasks: unfinished first, then by urgency (as in the planner)
    func today() -> [Item] {
        let d = Self.dayString()
        return tasks.filter { occurs($0, on: d) }
            .map { t -> Item in
                let s = subject(t["subj"])
                let subs = t["subs"] as? [[String: Any]] ?? []
                return Item(id: t["id"] as? String ?? UUID().uuidString,
                            title: t["title"] as? String ?? "",
                            urgency: (t["urg"] as? NSNumber)?.intValue ?? 5,
                            done: isDone(t, on: d),
                            colour: s?.colour,
                            subject: s?.name,
                            steps: (subs.filter { $0["d"] as? Bool == true }.count, subs.count),
                            repeats: (t["rep"] as? String ?? "none") != "none")
            }
            .sorted { a, b in a.done != b.done ? !a.done : a.urgency > b.urgency }
    }

    /// Unfinished one-off tasks from earlier days
    func overdueCount() -> Int {
        let d = Self.dayString()
        return tasks.filter {
            ($0["rep"] as? String ?? "none") == "none" && !($0["done"] as? Bool ?? false)
                && (($0["date"] as? String).map { $0 < d } ?? false)
        }.count
    }

    /// The next exam within two weeks, for the countdown
    func nextExam() -> Exam? {
        let d = Self.dayString()
        let exams = (state["exams"] as? [[String: Any]] ?? [])
            .filter { ($0["date"] as? String ?? "") >= d }
            .sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        guard let e = exams.first, let date = e["date"] as? String else { return nil }
        let days = Self.daysBetween(d, date)
        guard days <= 14 else { return nil }
        let s = subject(e["subj"])
        return Exam(id: e["id"] as? String ?? date, subject: s?.name ?? "Exam", colour: s?.colour,
                    days: days, period: e["per"].map { "\($0)" } ?? "")
    }

    // MARK: Changing, with the planner's own rules

    func toggle(_ id: String) {
        let d = Self.dayString()
        var list = tasks
        guard let i = list.firstIndex(where: { $0["id"] as? String == id }) else { return }
        var t = list[i]
        if (t["rep"] as? String ?? "none") == "none" {
            t["done"] = !(t["done"] as? Bool ?? false)
        } else {
            var on = t["doneOn"] as? [String: Any] ?? [:]
            if on[d] != nil { on[d] = nil } else { on[d] = true }
            t["doneOn"] = on
        }
        list[i] = t
        state["tasks"] = list
        commit()
    }

    /// "Read chapter 3 !8" adds a task for today with urgency 8, like the planner's own box
    func add(_ raw: String) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var urgency = 5
        if let r = title.range(of: #"(^|\s)!(10|[1-9])(?=\s|$)"#, options: .regularExpression) {
            urgency = Int(title[r].trimmingCharacters(in: .whitespaces).dropFirst()) ?? 5
            title.replaceSubrange(r, with: " ")
            title = title.trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return }
        if !hasData { state = ["v": 1, "subjects": [], "exams": [], "tasks": [], "free": []] }
        let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
        let task: [String: Any] = ["id": id, "title": title, "date": Self.dayString(), "subj": NSNull(),
                                   "urg": urgency, "done": false, "subs": [], "note": "", "rep": "none",
                                   "doneOn": [String: Any](), "skip": [String: Any](), "ex": NSNull()]
        state["tasks"] = tasks + [task]
        commit()
    }
}

private extension Color {
    /// "#3a8a48"
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}

// MARK: - The window

@MainActor
final class PlannerWindow: NSObject, NSWindowDelegate, WKScriptMessageHandlerWithReply {
    static let shared = PlannerWindow()
    private var window: NSWindow?
    private var web: WKWebView?
    private var madeRegular = false

    /// Stands in for claude.ai's `window.claude` so the page saves here instead
    private static let bridge = """
    (() => {
      const send = m => window.webkit.messageHandlers.planner.postMessage(m);
      const doc = { get: async () => { const t = await send({ op: 'get' });
                                       return { exists: !!t, data: () => (t ? JSON.parse(t) : null) }; },
                    set: async (obj) => { await send({ op: 'set', json: JSON.stringify(obj) }); } };
      window.claude = { use: async (name) => {
        if (name === 'user') return { id: async () => 'mac' };
        if (name === 'db') return { collection: () => ({ doc: () => doc }) };
        if (name === 'downloads') return { save: async (f) => { await send({ op: 'download', filename: f.filename, data: f.data }); } };
        return null;
      } };
    })();
    """

    func show() {
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
            madeRegular = true
        }
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let page = Bundle.main.url(forResource: "Planner", withExtension: "html") else {
            let a = NSAlert()
            a.messageText = "The planner page is missing"
            a.informativeText = "Rebuild Murmur with build-app.sh so Planner.html is included."
            a.runModal()
            return
        }
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "planner")
        let web = EditableWebView(frame: .zero, configuration: config)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        self.web = web

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Planner"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 500)
        w.setFrameAutosaveName("MurmurPlanner")
        if w.frame.origin == .zero { w.center() }
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The island changed something: the page re-reads its data (it does this whenever it's shown)
    func refreshPage() {
        web?.evaluateJavaScript("document.dispatchEvent(new Event('visibilitychange'))")
    }

    func windowWillClose(_ notification: Notification) {
        if madeRegular && NotchOnlyMode.isOn { NSApp.setActivationPolicy(.accessory) }
        madeRegular = false
        Task { @MainActor in
            self.web?.configuration.userContentController.removeScriptMessageHandler(forName: "planner", contentWorld: .page)
            self.web = nil
            self.window = nil
        }
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, nil)
            return
        }
        switch op {
        case "get":
            replyHandler(PlannerStore.shared.rawJSON, nil)
        case "set":
            if let json = body["json"] as? String { PlannerStore.shared.replace(with: json) }
            replyHandler(true, nil)
        case "download":
            let name = (body["filename"] as? String).map { ($0 as NSString).lastPathComponent } ?? "planner.txt"
            let text = body["data"] as? String ?? ""
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let url = downloads.appendingPathComponent(name)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(url)      // exams.ics opens straight in Calendar
                replyHandler(true, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        default:
            replyHandler(nil, nil)
        }
    }
}

/// Murmur has no Edit menu while it runs from the notch, so ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z are passed on here
/// (for pasting a backup in, and for typing tasks)
private final class EditableWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) .contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
        default: action = nil
        }
        if let a = action, NSApp.sendAction(a, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
