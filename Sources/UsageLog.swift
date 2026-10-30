import Foundation
import AppKit

// MARK: - Usage log
// Once a minute: the apps using noticeable memory or CPU, their bigger helper processes (each
// Safari website, for example), and the Mac's memory pressure. Optionally, every 5 minutes, which
// sites are open in Safari. Plain CSV files, one per day, kept for 14 days, on this Mac only.
// "Copy Report" turns the last 7 days into a short summary to paste into a chat.

final class UsageLog {
    static let shared = UsageLog()

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "usageLog") }
    static var includeSites: Bool { UserDefaults.standard.bool(forKey: "usageLogSites") }

    private let queue = DispatchQueue(label: "usage.log", qos: .utility)
    private var lastSites = Date.distantPast

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Murmur", isDirectory: true)
            .appendingPathComponent("UsageLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: Recording

    /// Called by the system monitor once a minute
    func record(apps: [AppUsage], memoryUsed: Double, pressure: MemoryPressure, cpu: Double) {
        let now = Date()
        let time = Self.stamp.string(from: now)
        var lines: [String] = []
        let pressureName = pressure == .normal ? "normal" : pressure == .warning ? "warning" : "critical"
        lines.append(Self.row(time, "SYSTEM", pressureName, 0, cpu * 100, memoryUsed / 1_048_576))

        let notable = apps.filter { $0.memory >= 100 * 1_048_576 || $0.cpu >= 5 }
            .sorted { $0.memory > $1.memory }
            .prefix(15)
        for app in notable {
            lines.append(Self.row(time, app.name, "(total)", app.processes.count, app.cpu, Double(app.memory) / 1_048_576))
            for p in app.processes where !p.isMain && p.memory >= 50 * 1_048_576 {
                lines.append(Self.row(time, app.name, p.name, Int(p.pid), p.cpu, Double(p.memory) / 1_048_576))
            }
        }
        append(lines, to: "usage", header: "time,app,process,pid_or_count,cpu_percent,memory_mb")

        if Self.includeSites, now.timeIntervalSince(lastSites) >= 300,
           NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty == false {
            lastSites = now
            recordSafariSites(time)
        }
    }

    private static func row(_ time: String, _ app: String, _ process: String, _ id: Int, _ cpu: Double, _ mb: Double) -> String {
        func clean(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
        return "\(time),\(clean(app)),\(clean(process)),\(id),\(String(format: "%.1f", cpu)),\(Int(mb.rounded()))"
    }

    /// Which websites are open in Safari (domains only), via Safari's own scripting
    private func recordSafariSites(_ time: String) {
        queue.async {
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"Safari\" to get URL of every tab of every window")
            guard let result = script?.executeAndReturnError(&error), error == nil else { return }
            var urls: [String] = []
            func collect(_ d: NSAppleEventDescriptor) {
                if d.numberOfItems > 0 {
                    for i in 1...d.numberOfItems { if let item = d.atIndex(i) { collect(item) } }
                } else if let s = d.stringValue {
                    urls.append(s)
                }
            }
            collect(result)
            var counts: [String: Int] = [:]
            for u in urls {
                guard let host = URL(string: u)?.host else { continue }
                counts[host.replacingOccurrences(of: "www.", with: ""), default: 0] += 1
            }
            let lines = counts.map { "\(time),\"\($0.key)\",\($0.value)" }
            self.writeLines(lines, name: "sites", header: "time,domain,tabs")
        }
    }

    private func append(_ lines: [String], to name: String, header: String) {
        queue.async { self.writeLines(lines, name: name, header: header) }
    }

    private func writeLines(_ lines: [String], name: String, header: String) {
        guard !lines.isEmpty else { return }
        let url = Self.folder.appendingPathComponent("\(name)-\(Self.day.string(from: Date())).csv")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data((header + "\n").utf8))
            prune()
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Keeps 14 days
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            guard let dash = name.firstIndex(of: "-"),
                  let d = Self.day.date(from: String(name[name.index(after: dash)...])) else { continue }
            if d < cutoff { try? fm.removeItem(at: f) }
        }
    }

    func deleteAll() {
        queue.async {
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: f)
            }
        }
    }

    // MARK: Report

    /// The last 7 days, summarised in plain text
    func report() -> String {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let cutoff = Self.day.string(from: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        func recent(_ prefix: String) -> [URL] {
            files.filter {
                let n = $0.deletingPathExtension().lastPathComponent
                return n.hasPrefix(prefix + "-") && String(n.dropFirst(prefix.count + 1)) >= cutoff
            }
        }

        struct Stat { var n = 0; var mem = 0.0; var peak = 0.0; var cpu = 0.0; var peakCPU = 0.0; var count = 0.0 }
        var apps: [String: Stat] = [:]
        var helpers: [String: Stat] = [:]
        var pressure: [String: Int] = [:]
        var systemMem: [Double] = []
        var systemCPU: [Double] = []
        var minutes = Set<String>()
        var helperCounts: [String: [String: Int]] = [:]       // minute → app|helper → count

        for file in recent("usage") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let f = Self.parse(String(line))
                guard f.count == 6, let cpu = Double(f[4]), let mb = Double(f[5]) else { continue }
                minutes.insert(f[0])
                if f[1] == "SYSTEM" {
                    pressure[f[2], default: 0] += 1
                    systemMem.append(mb)
                    systemCPU.append(cpu)
                } else if f[2] == "(total)" {
                    var s = apps[f[1]] ?? Stat()
                    s.n += 1; s.mem += mb; s.peak = max(s.peak, mb); s.cpu += cpu; s.peakCPU = max(s.peakCPU, cpu)
                    s.count += Double(f[3]) ?? 0
                    apps[f[1]] = s
                } else {
                    let key = "\(f[1]) › \(f[2])"
                    var s = helpers[key] ?? Stat()
                    s.n += 1; s.mem += mb; s.peak = max(s.peak, mb); s.cpu += cpu
                    helpers[key] = s
                    helperCounts[f[0], default: [:]][key, default: 0] += 1
                }
            }
        }

        var sites: [String: Int] = [:]
        var siteSnapshots = Set<String>()
        for file in recent("sites") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let f = Self.parse(String(line))
                guard f.count == 3 else { continue }
                siteSnapshots.insert(f[0])
                sites[f[1], default: 0] += 1
            }
        }

        guard !minutes.isEmpty else {
            return "Murmur usage report: no data yet. Turn on the usage log in Settings › System and use your Mac for a while."
        }

        func gb(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb.rounded())) MB" }
        let total = Double(minutes.count)
        let ram = Int((ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
        var out: [String] = []
        let sorted = minutes.sorted()
        out.append("VISUALISER USAGE REPORT · \(sorted.first ?? "") to \(sorted.last ?? "")")
        out.append("\(minutes.count) one-minute snapshots (\(String(format: "%.1f", total / 60)) hours) · Mac with \(ram) GB memory")
        if !systemMem.isEmpty {
            let avg = systemMem.reduce(0, +) / Double(systemMem.count)
            let pk = systemMem.max() ?? 0
            let cpuAvg = systemCPU.reduce(0, +) / Double(max(1, systemCPU.count))
            out.append("Memory in use: average \(gb(avg)), peak \(gb(pk)) · whole-Mac CPU average \(Int(cpuAvg))%")
            let parts = ["normal", "warning", "critical"].map { k -> String in
                let pct = Double(pressure[k] ?? 0) / Double(max(1, systemMem.count)) * 100
                return "\(k) \(String(format: "%.0f", pct))%"
            }
            out.append("Memory pressure: " + parts.joined(separator: " · "))
        }

        out.append("")
        out.append("APPS (by average memory while running; CPU 100% = one core)")
        for (name, s) in apps.sorted(by: { $0.value.mem / Double($0.value.n) > $1.value.mem / Double($1.value.n) }).prefix(12) {
            let n = Double(s.n)
            out.append("- \(name): avg \(gb(s.mem / n)), peak \(gb(s.peak)), avg CPU \(Int((s.cpu / n).rounded()))%, peak CPU \(Int(s.peakCPU.rounded()))%, about \(Int((s.count / n).rounded())) processes, seen \(String(format: "%.0f", n / total * 100))% of the time")
        }

        if !helpers.isEmpty {
            out.append("")
            out.append("BIGGER HELPER PROCESSES (50 MB or more)")
            var mostAtOnce: [String: Int] = [:]
            for (_, m) in helperCounts { for (k, c) in m { mostAtOnce[k] = max(mostAtOnce[k] ?? 0, c) } }
            for (key, s) in helpers.sorted(by: { $0.value.peak > $1.value.peak }).prefix(10) {
                let n = Double(s.n)
                out.append("- \(key): up to \(mostAtOnce[key] ?? 1) at once, each avg \(gb(s.mem / n)), biggest \(gb(s.peak)), avg CPU \(Int((s.cpu / n).rounded()))%")
            }
        }

        if !sites.isEmpty {
            out.append("")
            out.append("SAFARI SITES (share of 5-minute checks where the site was open)")
            let checks = Double(max(1, siteSnapshots.count))
            for (host, c) in sites.sorted(by: { $0.value > $1.value }).prefix(15) {
                out.append("- \(host): \(String(format: "%.0f", Double(c) / checks * 100))%")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Splits a CSV line, respecting quotes
    private static func parse(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            else if ch == "," && !quoted { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        fields.append(current)
        return fields
    }
}
