import SwiftUI
import AppKit
import Network

// MARK: - Approving Claude Code from the notch
//
// Claude Code (running on this Mac: Terminal, the desktop app, or an editor) can ask another program
// before it shows its own permission prompt, through a "PermissionRequest" hook. Murmur installs a
// small hook that forwards each request to Murmur on this Mac only (127.0.0.1). The island shows it with
// Allow / Deny, and the answer goes back to Claude Code. If Murmur isn't running, doesn't answer in time,
// or you pick "Terminal", Claude Code simply asks in its own window as usual.
//
// Cloud sessions (claude.ai/code in the browser) run on Anthropic's servers and can't reach this Mac,
// so they keep their own prompts.

struct ClaudeRequest: Equatable, Identifiable {
    let id = UUID()
    let tool: String          // "Bash", "Edit", "WebFetch", …
    let summary: String       // the command, file or address it's about
    let project: String       // the folder Claude Code is working in

    static func == (a: ClaudeRequest, b: ClaudeRequest) -> Bool { a.id == b.id }

    /// "Run a command", "Edit a file", …
    var action: String {
        switch tool {
        case "Bash": return "Run a command"
        case "Edit", "MultiEdit": return "Edit a file"
        case "Write": return "Write a file"
        case "Read": return "Read a file"
        case "NotebookEdit": return "Edit a notebook"
        case "WebFetch": return "Open a web page"
        case "WebSearch": return "Search the web"
        default: return tool.hasPrefix("mcp__") ? "Use \(tool.split(separator: "_").dropFirst(2).first.map(String.init) ?? "a tool")" : "Use \(tool)"
        }
    }

    var symbol: String {
        switch tool {
        case "Bash": return "terminal"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Read": return "doc.text"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class ClaudeBridge {
    static let shared = ClaudeBridge()

    static let wait = ClaudeHook.wait
    static var enabled: Bool { ClaudeHook.enabled }

    private var listener: NWListener?
    private var queue: [(request: ClaudeRequest, reply: (String?) -> Void)] = []
    private(set) var current: ClaudeRequest?
    private(set) var listening = false

    // MARK: Starting and stopping

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ClaudeHook.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { conn in
            Task { @MainActor in ClaudeBridge.shared.accept(conn) }
        }
        l.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: ClaudeBridge.shared.listening = true
                case .failed, .cancelled: ClaudeBridge.shared.listening = false
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        listening = false
        // Anything still waiting goes back to Claude Code's own prompt
        let waiting = queue
        queue = []
        for item in waiting { item.reply(nil) }
        if current != nil { finishCurrent() }
    }

    // MARK: HTTP (just enough of it: one POST, one answer)

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            Task { @MainActor in
                var buf = buffer
                if let d = data { buf.append(d) }
                if let request = Self.parse(buf) {
                    ClaudeBridge.shared.handle(request, conn: conn)
                } else if done || error != nil || buf.count > 1_000_000 {
                    conn.cancel()
                } else {
                    ClaudeBridge.shared.read(conn, buffer: buf)
                }
            }
        }
    }

    private struct HTTPRequest {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Nil until the whole request (headers and body) has arrived
    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ conn: NWConnection, status: String = "200 OK", json: String?) {
        let body = Data((json ?? "").utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ http: HTTPRequest, conn: NWConnection) {
        guard http.path == ClaudeHook.path, http.headers["x-murmur-token"] == ClaudeHook.token else {
            respond(conn, status: "403 Forbidden", json: nil)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: http.body) as? [String: Any] else {
            respond(conn, json: nil)
            return
        }
        // Only permission questions; anything else is left alone
        if let event = json["hook_event_name"] as? String, event != "PermissionRequest" {
            respond(conn, json: nil)
            return
        }
        let tool = json["tool_name"] as? String ?? "a tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let summary = (input["command"] as? String)
            ?? (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input["url"] as? String)
            ?? (input["query"] as? String)
            ?? (input["description"] as? String)
            ?? ""
        let project = ((json["cwd"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
        let request = ClaudeRequest(tool: tool, summary: summary, project: project)

        // No island to show it on: let Claude Code ask as usual
        guard NotchController.shared.isRunning else {
            respond(conn, json: nil)
            return
        }

        var answered = false
        let reply: (String?) -> Void = { [weak self] behavior in
            guard !answered else { return }
            answered = true
            guard let behavior = behavior else { self?.respond(conn, json: nil); return }
            var decision: [String: Any] = ["behavior": behavior]
            if behavior == "deny" { decision["message"] = "Denied from the notch" }
            let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                             "decision": decision]]
            let text = (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) }
            self?.respond(conn, json: text)
        }
        queue.append((request, reply))
        // Not answered in time: back to Claude Code's own prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wait) { [weak self] in
            guard let self = self, !answered else { return }
            reply(nil)
            if self.current?.id == request.id { self.finishCurrent() } else {
                self.queue.removeAll { $0.request.id == request.id }
            }
        }
        if current == nil { showNext() }
    }

    // MARK: The island

    private func showNext() {
        guard let next = queue.first else { current = nil; return }
        current = next.request
        NotchController.shared.showApproval(next.request)
    }

    /// From the island's buttons: "allow", "deny", or nil (answer in Claude Code instead)
    func decide(_ behavior: String?) {
        guard let c = current, let index = queue.firstIndex(where: { $0.request.id == c.id }) else {
            finishCurrent()
            return
        }
        let item = queue.remove(at: index)
        item.reply(behavior)
        finishCurrent()
    }

    private func finishCurrent() {
        current = nil
        NotchController.shared.dismissApproval()
        if !queue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showNext() }
        }
    }
}

/// Everything about the hook itself, usable from anywhere (settings, the listener)
enum ClaudeHook {
    static let port: UInt16 = 47823
    static let path = "/claude/permission"
    /// How long the island waits before handing the question back to Claude Code's own prompt
    static let wait: TimeInterval = 50

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "claudeApprovals") as? Bool ?? false
    }

    /// A secret only Murmur and the hook know, so other programs on this Mac can't send fake requests
    static var token: String {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "claudeToken"), t.count >= 32 { return t }
        let t = (0..<32).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
        d.set(t, forKey: "claudeToken")
        return t
    }

    // MARK: Installing the hook into Claude Code's settings

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The command Claude Code runs for each permission question. `|| true`: if Murmur isn't there,
    /// it prints nothing and Claude Code asks as usual.
    static var hookCommand: String {
        "curl -sf -m \(Int(wait) + 5) -X POST -H 'Content-Type: application/json' "
            + "-H 'X-Murmur-Token: \(token)' --data-binary @- http://127.0.0.1:\(port)\(path) || true"
    }

    static var hookEntry: [String: Any] {
        ["matcher": "*",
         "hooks": [["type": "command", "command": hookCommand, "timeout": Int(wait) + 10]]]
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("127.0.0.1:\(port)\(path)") && text.contains(token)
    }

    /// Adds the hook to ~/.claude/settings.json, keeping everything else (a backup is saved first)
    static func install() -> String? {
        let fm = FileManager.default
        let url = settingsURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Your Claude Code settings file couldn't be read. Use Copy instead and paste it in yourself."
            }
            root = parsed
            try? fm.removeItem(at: url.appendingPathExtension("murmur-backup"))
            try? fm.copyItem(at: url, to: url.appendingPathExtension("murmur-backup"))
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var list = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        list.removeAll { isOurs($0) }
        list.append(hookEntry)
        hooks["PermissionRequest"] = list
        root["hooks"] = hooks
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "Couldn't save Claude Code's settings: \(error.localizedDescription)"
        }
    }

    /// Takes the hook out again
    static func uninstall() {
        guard let data = try? Data(contentsOf: settingsURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any],
              var list = hooks["PermissionRequest"] as? [[String: Any]] else { return }
        list.removeAll { isOurs($0) }
        if list.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = list }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL, options: .atomic)
        }
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String)?.contains("127.0.0.1:\(port)\(path)") == true }
    }

    /// The same settings, for pasting by hand
    static var snippet: String {
        let root: [String: Any] = ["hooks": ["PermissionRequest": [hookEntry]]]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - The card in the island

struct ApprovalCard: View {
    let request: ClaudeRequest
    let notch: CGSize
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkle")
                    .font(.system(size: max(12, notch.height * 0.42), weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                    .symbolBounce(appeared)
                Spacer(minLength: 0)
                if !request.project.isEmpty {
                    Text(request.project)
                        .font(IslandType.small)
                        .foregroundStyle(IslandType.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: notch.height)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.1)))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code: \(request.action)")
                        .font(IslandType.title)
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    if !request.summary.isEmpty {
                        Text(request.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(IslandType.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(request.summary)
                    }
                    HStack(spacing: 6) {
                        pill("Allow", primary: true) { ClaudeBridge.shared.decide("allow") }
                        pill("Deny", primary: false) { ClaudeBridge.shared.decide("deny") }
                        pill("Ask in Claude", primary: false) { ClaudeBridge.shared.decide(nil) }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { appeared = true } }
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
    }
}
