import SwiftUI
import AppKit

// MARK: - The System tab in the island

struct SystemTabView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Gauge2(label: "CPU", value: monitor.cpu, text: percent(monitor.cpu),
                       selected: monitor.pick == .cpu) { select(.cpu) }
                Gauge2(label: "GPU", value: monitor.gpu ?? 0, text: monitor.gpu.map(percent) ?? "–",
                       selected: monitor.pick == .gpu) { select(.gpu) }
                Gauge2(label: "Memory", value: monitor.memoryUsed / monitor.memoryTotal,
                       text: String(format: "%.0f", monitor.memoryUsed / 1_073_741_824) + "G",
                       tint: pressureTint, selected: monitor.pick == .memory) { select(.memory) }
                temperatureGauge
                batteryGauge
                networkGauge
            }

            listHeader

            VStack(spacing: 2) {
                let category = monitor.pick.category
                let rows = monitor.top(category, 3)
                ForEach(rows) { app in
                    let cols = monitor.columns(app, category)
                    AppRow(app: app, primary: cols.0, secondary: cols.1,
                           warn: category == .cpu && app.cpu >= 80)
                }
                if rows.isEmpty {
                    Text(emptyText(category))
                        .font(IslandType.subtitle)
                        .foregroundStyle(IslandType.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                ForEach(0..<max(0, 3 - max(1, rows.count)), id: \.self) { _ in
                    Color.clear.frame(height: 22)
                }
            }
            .animation(Motion.spring(0.35, 0.9), value: monitor.pick)
        }
    }

    private func select(_ pick: SystemPick) {
        NotchController.haptic(.generic)
        withAnimation(Motion.spring(0.3, 0.85)) { monitor.pick = pick }
    }

    /// What the list is sorted by, and the two column titles, lined up with the numbers below
    private var listHeader: some View {
        let category = monitor.pick.category
        let titles = SystemMonitor.columnTitles(category)
        return HStack(spacing: 8) {
            Text(category == .network ? monitor.network.summary
                 : monitor.pick == .temp ? "Making the most heat" : category.heading)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 6)
            Text(titles.0).frame(width: 64, alignment: .trailing)
            Text(titles.1).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 20, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(IslandType.tertiary)
        .padding(.horizontal, 6)
    }

    private func emptyText(_ category: UsageCategory) -> String {
        switch category {
        case .gpu: return monitor.gpuPerApp ? "Nothing is using the GPU" : "This Mac doesn't report GPU use per app"
        case .network: return monitor.networkPerApp ? "Nothing is using the network" : "Measuring…"
        default: return "Measuring…"
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// Memory is coloured by pressure (how hard macOS is working to fit everything), not by % used
    private var pressureTint: Color {
        switch monitor.pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    @ViewBuilder
    private var temperatureGauge: some View {
        if let t = monitor.temperature {
            Gauge2(label: "Temp", value: (t - 30) / 70, text: "\(Int(t.rounded()))°",
                   tint: t < 70 ? .green : t < 88 ? .yellow : .red,
                   selected: monitor.pick == .temp) { select(.temp) }
        } else {
            // macOS's own heat level, when the sensors can't be read
            let (word, level, tint): (String, Double, Color) = {
                switch monitor.thermal {
                case .nominal: return ("Cool", 0.25, .green)
                case .fair: return ("Warm", 0.5, .yellow)
                case .serious: return ("Hot", 0.8, .orange)
                case .critical: return ("Hot!", 1, .red)
                @unknown default: return ("–", 0, .gray)
                }
            }()
            Gauge2(label: "Heat", value: level, text: word, tint: tint,
                   selected: monitor.pick == .temp) { select(.temp) }
        }
    }

    @ViewBuilder
    private var batteryGauge: some View {
        if let b = monitor.battery {
            Gauge2(label: b.charging ? "Charging" : "Battery", value: Double(b.percent) / 100,
                   text: "\(b.percent)%",
                   tint: b.percent <= 10 ? .red : b.percent <= 20 ? .orange : .green,
                   detail: SystemTabView.batteryDetail(b),
                   selected: monitor.pick == .energy) { select(.energy) }
        } else {
            Gauge2(label: "Energy", value: 1, text: "AC", tint: .green,
                   selected: monitor.pick == .energy) { select(.energy) }
        }
    }

    /// Download speed in the ring (on a log scale, so small and big transfers both register);
    /// the connection in the label, coloured by whether the internet answers
    private var networkGauge: some View {
        let n = monitor.network
        let total = n.down + n.up
        let level = n.link == .offline ? 0 : min(1, log10(1 + total) / 8)
        let tint: Color = n.link == .offline ? .red : n.internet == false ? .orange : .green
        let label = n.link == .offline ? "Offline" : n.internet == false ? "No Internet" : n.linkName
        return Gauge2(label: label, value: level,
                      text: n.link == .offline ? "Off" : SystemMonitor.shortRate(n.down),
                      tint: tint,
                      detail: "\(n.summary)\n↓ \(SystemMonitor.rate(n.down))   ↑ \(SystemMonitor.rate(n.up))",
                      selected: monitor.pick == .network) { select(.network) }
    }

    static func batteryDetail(_ b: BatteryInfo) -> String {
        var parts: [String] = []
        if let m = b.minutesLeft { parts.append(b.charging ? "Full in \(SystemMonitor.duration(m))" : "\(SystemMonitor.duration(m)) left") }
        if let h = b.health { parts.append("Health \(h)%") }
        if let c = b.cycles { parts.append("\(c) cycles") }
        return parts.joined(separator: " · ")
    }
}

/// A small ring with the value inside and a label below; click it to list the apps behind it
private struct Gauge2: View {
    let label: String
    let value: Double
    let text: String
    var tint: Color? = nil
    var detail: String? = nil
    var selected = false
    var action: () -> Void = {}
    @State private var hovering = false

    private var colour: Color {
        if let t = tint { return t }
        return value < 0.6 ? .green : value < 0.85 ? .yellow : .red
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 3.5)
                    Circle()
                        .trim(from: 0, to: CGFloat(min(1, max(0.001, value))))
                        .stroke(colour, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Motion.spring(0.6, 0.85), value: value)
                    Text(text)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
                .frame(width: 38, height: 38)
                Text(label)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : IslandType.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(detail.map { $0.isEmpty ? label : $0 } ?? label)
    }
}

/// One of the heaviest apps, with two numbers for the picked category and a quit button
private struct AppRow: View {
    let app: AppUsage
    let primary: String
    let secondary: String
    var warn = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(app: app, size: 18)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(primary)
                .font(IslandType.small)
                .foregroundStyle(warn ? Color.orange : IslandType.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
            Text(secondary)
                .font(IslandType.small)
                .foregroundStyle(IslandType.tertiary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)

            QuitButton(app: app, visible: hovering, size: 13)
        }
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
    }
}

/// The app's own icon, or a gear for background processes
struct AppIcon: View {
    let app: AppUsage
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let p = app.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable()
            } else {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(IslandType.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct QuitButton: View {
    let app: AppUsage
    var visible: Bool
    var size: CGFloat = 13

    var body: some View {
        Button {
            NotchController.haptic(.generic)
            SystemMonitor.shared.quit(app)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Color.white.opacity(visible ? 0.8 : 0.35))
                .frame(width: size + 7, height: size + 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .opacity(app.canQuit ? 1 : 0)
        .disabled(!app.canQuit)
        .help("Quit \(app.name)")
    }
}

// MARK: - The alert card that drops from the notch

struct AlertView: View {
    let alert: SystemAlert
    let notch: CGSize
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // In the ears: the app's icon on the left, the number on the right
            HStack {
                icon
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                Spacer(minLength: 0)
                Text(alert.value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(valueColour)
            }
            .frame(height: notch.height)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(IslandType.title)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(alert.subtitle)
                    .font(IslandType.subtitle)
                    .foregroundStyle(IslandType.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(Motion.spring(0.5, 0.6).delay(0.1)) { appeared = true }
        }
    }

    private var valueColour: Color {
        switch alert.kind {
        case .battery: return .orange
        case .heat, .cpu: return .orange
        default: return .white
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let p = alert.appPath, alert.kind == .cpu || alert.kind == .notResponding {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                .resizable()
                .frame(width: max(16, notch.height - 12), height: max(16, notch.height - 12))
        } else {
            Image(systemName: alert.symbol)
                .font(.system(size: max(12, notch.height * 0.42), weight: .medium))
                .foregroundStyle(alert.kind == .battery || alert.kind == .heat ? Color.orange : Color.white)
                .symbolBounce(appeared)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch alert.kind {
        case .cpu, .memory:
            if alert.appPath != nil {
                pill("Don't Warn Again", primary: false) {
                    SystemMonitor.shared.ignoreForever(alert.appID)
                    NotchController.shared.dismissActivity()
                }
                pill("Ignore", primary: false) {
                    SystemMonitor.shared.snooze(alert.appID, minutes: 60)
                    NotchController.shared.dismissActivity()
                }
                pill("Quit", primary: true) {
                    let target = SystemMonitor.shared.apps.first { $0.id == alert.appID }
                    if let t = target { SystemMonitor.shared.quit(t) }
                    NotchController.shared.dismissActivity()
                }
            } else {
                pill("OK", primary: true) { NotchController.shared.dismissActivity() }
            }
        case .notResponding:
            pill("Cancel", primary: false) { NotchController.shared.dismissActivity() }
            pill("Force Quit", primary: true) {
                SystemMonitor.shared.forceQuit(path: alert.appPath)
                NotchController.shared.dismissActivity()
            }
        case .battery, .heat:
            pill("OK", primary: true) { NotchController.shared.dismissActivity() }
        }
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
    }
}
