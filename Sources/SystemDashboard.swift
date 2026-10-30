import SwiftUI
import AppKit

// MARK: - The full-screen System view: live graphs and every app, sortable by category

@MainActor
final class SystemDashboard: NSObject, NSWindowDelegate {
    static let shared = SystemDashboard()
    private var window: NSWindow?
    private var closeAfterLeavingFullScreen = false
    private var keyMonitor: Any?
    private var madeRegular = false

    func show() {
        // In Notch Only the app has no Dock icon; a full-screen window needs one while it's open
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
            madeRegular = true
        }
        SystemMonitor.shared.setDashboard(true)

        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(rootView: SystemDashboardView(close: { SystemDashboard.shared.close() }))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "System"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.045, alpha: 1)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.setContentSize(NSSize(width: 1180, height: 800))
        w.minSize = NSSize(width: 900, height: 600)
        w.center()
        w.delegate = self
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        // Esc closes it
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak w] event in
            guard event.keyCode == 53, let w = w, event.window === w else { return event }
            Task { @MainActor in SystemDashboard.shared.close() }
            return nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
    }

    func close() {
        guard let w = window else { return }
        if w.styleMask.contains(.fullScreen) {
            // Leave full screen first, so the Space slides away before the window disappears
            closeAfterLeavingFullScreen = true
            w.toggleFullScreen(nil)
        } else {
            w.close()
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if closeAfterLeavingFullScreen {
            closeAfterLeavingFullScreen = false
            window?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        SystemMonitor.shared.setDashboard(false)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if madeRegular && NotchOnlyMode.isOn { NSApp.setActivationPolicy(.accessory) }
        madeRegular = false
        Task { @MainActor in self.window = nil }
    }
}

// MARK: - The view

private enum DashColour {
    static let background = Color(white: 0.045)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let cpu = Color(red: 0.35, green: 0.78, blue: 0.98)
    static let gpu = Color(red: 0.69, green: 0.52, blue: 1.0)
    static let memory = Color(red: 0.3, green: 0.85, blue: 0.5)
    static let temp = Color(red: 1.0, green: 0.62, blue: 0.25)
    static let energy = Color(red: 1.0, green: 0.84, blue: 0.3)
    static let down = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let up = Color(red: 1.0, green: 0.42, blue: 0.62)
}

struct SystemDashboardView: View {
    var close: () -> Void
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var expanded: Set<String> = []
    @State private var showFreeUp = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: columns, spacing: 14) {
                    cpuCard
                    gpuCard
                    memoryCard
                    tempCard
                    energyCard
                    networkCard
                }
                appsCard
            }
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 30)
        }
        .background(DashColour.background)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(DashColour.secondary)
            }
            Spacer()
            Button { showFreeUp = true } label: {
                Label("Free Up Memory", systemImage: "memorychip")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(PressableStyle())
            .sheet(isPresented: $showFreeUp) { FreeUpView() }
            Button(action: close) {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(PressableStyle())
            .help("Close (Esc)")
        }
    }

    private var subtitle: String {
        let up = Int(ProcessInfo.processInfo.systemUptime / 60)
        let upText = up >= 1440 ? "\(up / 1440) d \(up % 1440 / 60) h" : SystemMonitor.duration(up)
        let ram = Int((monitor.memoryTotal / 1_073_741_824).rounded())
        return "Up \(upText) · \(ProcessInfo.processInfo.activeProcessorCount) cores · \(ram) GB memory · \(monitor.network.summary)"
    }

    // MARK: Cards

    private func topName(_ c: UsageCategory) -> String? {
        monitor.top(c, 1).first.map { $0.name }
    }

    private var cpuCard: some View {
        MetricCard(title: "CPU", value: percent(monitor.cpu),
                   detail: topName(.cpu).map { "Busiest: \($0)" } ?? "Whole chip",
                   series: [GraphSeries(values: monitor.history.cpu, colour: DashColour.cpu, fill: true)],
                   range: 0...1, selected: monitor.pick == .cpu) { pick(.cpu) }
    }

    private var gpuCard: some View {
        MetricCard(title: "GPU", value: monitor.gpu.map(percent) ?? "–",
                   detail: monitor.gpuPerApp ? (topName(.gpu).map { "Busiest: \($0)" } ?? "Idle") : "Whole GPU",
                   series: [GraphSeries(values: monitor.history.gpu, colour: DashColour.gpu, fill: true)],
                   range: 0...1, selected: monitor.pick == .gpu) { pick(.gpu) }
    }

    private var memoryCard: some View {
        let pressure: String = {
            switch monitor.pressure {
            case .normal: return "pressure normal"
            case .warning: return "pressure high"
            case .critical: return "pressure critical"
            }
        }()
        let total = Int((monitor.memoryTotal / 1_073_741_824).rounded())
        return MetricCard(title: "Memory", value: String(format: "%.1f GB", monitor.memoryUsed / 1_073_741_824),
                          detail: "of \(total) GB · \(pressure)",
                          series: [GraphSeries(values: monitor.history.memory, colour: pressureColour, fill: true)],
                          range: 0...1, selected: monitor.pick == .memory) { pick(.memory) }
    }

    private var pressureColour: Color {
        switch monitor.pressure {
        case .normal: return DashColour.memory
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    private var tempCard: some View {
        let value: String
        let detail: String
        if let t = monitor.temperature {
            value = "\(Int(t.rounded()))°C"
            detail = "Hottest chip sensor · " + thermalWord
        } else {
            value = thermalWord
            detail = "macOS heat level (sensors unavailable)"
        }
        return MetricCard(title: "Temperature", value: value, detail: detail,
                          series: [GraphSeries(values: monitor.history.temp, colour: DashColour.temp, fill: true)],
                          range: 30...105, selected: monitor.pick == .temp) { pick(.temp) }
    }

    private var thermalWord: String {
        switch monitor.thermal {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        @unknown default: return "–"
        }
    }

    private var energyCard: some View {
        let appsTotal = monitor.usage.reduce(0.0) { $0 + $1.energy }
        let appsText = monitor.energyInWatts ? "Apps using \(monitor.energyText(appsTotal))"
                                             : "Energy impact \(monitor.energyText(appsTotal))"
        let value: String
        var detail = appsText
        if let b = monitor.battery {
            value = "\(b.percent)%"
            let state = b.charging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery"
            let extra = SystemTabView.batteryDetail(b)
            detail = [state, extra.isEmpty ? nil : extra].compactMap { $0 }.joined(separator: " · ")
                + "\n" + appsText
        } else {
            value = monitor.energyInWatts ? monitor.energyText(appsTotal) : "AC"
        }
        return MetricCard(title: monitor.battery == nil ? "Energy" : "Battery & Energy", value: value,
                          detail: detail,
                          series: [GraphSeries(values: monitor.history.energy, colour: DashColour.energy, fill: true)],
                          range: nil, selected: monitor.pick == .energy) { pick(.energy) }
    }

    private var networkCard: some View {
        let n = monitor.network
        return MetricCard(title: "Network", value: "↓ " + SystemMonitor.rate(n.down),
                          detail: "↑ \(SystemMonitor.rate(n.up)) · \(n.summary)",
                          series: [GraphSeries(values: monitor.history.down, colour: DashColour.down, fill: true),
                                   GraphSeries(values: monitor.history.up, colour: DashColour.up, fill: false)],
                          range: nil, selected: monitor.pick == .network,
                          status: n.link == .offline ? .red : n.internet == false ? .orange
                                : n.internet == true ? .green : nil) { pick(.network) }
    }

    private func pick(_ p: SystemPick) {
        withAnimation(Motion.spring(0.35, 0.85)) { monitor.pick = p }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: Apps

    private var category: UsageCategory { monitor.pick.category }

    private var categoryBinding: Binding<UsageCategory> {
        Binding(get: { monitor.pick.category },
                set: { c in pick(SystemPick(rawValue: c.rawValue) ?? .cpu) })
    }

    private var appsCard: some View {
        let rows = monitor.top(category, 10)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monitor.pick == .temp ? "Making the most heat" : category.heading)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer()
                Picker("Sort by", selection: categoryBinding) {
                    ForEach(UsageCategory.allCases) { c in Text(c.title).tag(c) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)
            }
            .padding(.bottom, 4)

            DashRowLayout(name: Text("App"),
                          cells: UsageCategory.allCases.flatMap { headerCells($0) },
                          quit: AnyView(Color.clear))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashColour.tertiary)

            ForEach(rows) { app in
                let open = expanded.contains(app.id)
                DashAppRow(app: app, sortedBy: category, expanded: open) {
                    withAnimation(Motion.spring(0.3, 0.9)) {
                        if open { expanded.remove(app.id) } else { expanded.insert(app.id) }
                    }
                }
                if open {
                    ForEach(Array(app.processes.sorted { $0.memory > $1.memory }.prefix(15))) { p in
                        DashProcessRow(process: p)
                    }
                    .transition(.opacity)
                }
            }
            if rows.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(DashColour.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DashColour.card))
        .animation(Motion.spring(0.35, 0.9), value: monitor.pick)
    }

    private var emptyText: String {
        switch category {
        case .gpu: return monitor.gpuPerApp ? "Nothing is using the GPU" : "This Mac doesn't report GPU use per app"
        case .network: return monitor.networkPerApp ? "Nothing is using the network right now" : "Measuring…"
        default: return "Measuring…"
        }
    }

    /// Column titles; click one to sort by it. Network has two columns (down and up).
    private func headerCells(_ c: UsageCategory) -> [DashCell] {
        let on = category == c
        let colour = on ? Color.white : DashColour.tertiary
        func cell(_ title: String, _ width: CGFloat) -> DashCell {
            DashCell(width: width, view: AnyView(
                Button { pick(SystemPick(rawValue: c.rawValue) ?? .cpu) } label: {
                    HStack(spacing: 3) {
                        Text(title)
                        if on && title != "Up" {
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundStyle(colour)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)))
        }
        if c == .network { return [cell("Down", DashWidths.network), cell("Up", DashWidths.network)] }
        return [cell(c.title, DashWidths.width(c))]
    }
}

// MARK: - Table pieces

private enum DashWidths {
    static let network: CGFloat = 96
    static func width(_ c: UsageCategory) -> CGFloat {
        switch c {
        case .cpu, .gpu: return 70
        case .memory: return 90
        case .energy: return 84
        case .network: return network
        }
    }
}

private struct DashCell {
    let width: CGFloat
    let view: AnyView
}

/// The app name on the left, then fixed-width numeric columns, then the quit button
private struct DashRowLayout: View {
    let name: Text
    let cells: [DashCell]
    let quit: AnyView

    var body: some View {
        HStack(spacing: 0) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            ForEach(cells.indices, id: \.self) { i in
                cells[i].view.frame(width: cells[i].width, alignment: .trailing)
            }
            quit.frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
    }
}

private struct DashAppRow: View {
    let app: AppUsage
    let sortedBy: UsageCategory
    var expanded = false
    var toggle: () -> Void = {}
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                // Apps made of several processes open up to show them
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DashColour.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(app.processes.count > 1 ? 1 : 0)
                    .frame(width: 10)
                AppIcon(app: app, size: 20)
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                if app.processes.count > 1 {
                    Text("\(app.processes.count) processes")
                        .font(.system(size: 11))
                        .foregroundStyle(DashColour.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if app.processes.count > 1 { toggle() } }

            cell("\(Int(app.cpu.rounded()))%", .cpu, warn: app.cpu >= 80)
            cell(monitor.gpuPerApp ? "\(Int((app.gpu * 100).rounded()))%" : "–", .gpu)
            cell(SystemMonitor.bytes(app.memory), .memory)
            cell(monitor.energyText(app.energy), .energy)
            cell(monitor.networkPerApp ? SystemMonitor.rate(app.down) : "–", .network)
            cell(monitor.networkPerApp ? SystemMonitor.rate(app.up) : "–", .network)

            QuitButton(app: app, visible: hovering, size: 15)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(hovering || expanded ? 0.06 : 0)))
        .onHover { hovering = $0 }
    }

    private func cell(_ text: String, _ c: UsageCategory, warn: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: sortedBy == c ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(warn ? Color.orange : sortedBy == c ? Color.white : DashColour.secondary)
            .lineLimit(1)
            .frame(width: DashWidths.width(c), alignment: .trailing)
    }
}

/// One process inside an app, with a button to end it (helpers only)
private struct DashProcessRow: View {
    let process: ProcessUsage
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(process.isMain ? "\(process.name) (the app itself)" : process.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                Text("\(process.pid)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(DashColour.tertiary)
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(Int(process.cpu.rounded()))%")
                .frame(width: DashWidths.width(.cpu), alignment: .trailing)
            Color.clear.frame(width: DashWidths.width(.gpu))
            Text(SystemMonitor.bytes(process.memory))
                .frame(width: DashWidths.width(.memory), alignment: .trailing)
            Color.clear.frame(width: DashWidths.width(.energy) + DashWidths.network * 2)

            Button {
                NotchController.haptic(.generic)
                SystemMonitor.shared.end(process)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(hovering ? 0.75 : 0.3))
            }
            .buttonStyle(PressableStyle())
            .opacity(process.canEnd ? 1 : 0)
            .disabled(!process.canEnd)
            .help(process.name == "Web page"
                  ? "End this page's process to free its memory (the page reloads when you next look at it)"
                  : "End this process")
            .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(DashColour.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Free Up Memory

/// What actually frees memory (closing things), plus the cache-clearing other apps offer,
/// labelled for what it is
struct FreeUpView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @Environment(\.dismiss) private var dismiss
    @State private var clearing = false
    @State private var cacheResult: String?

    private var apps: [AppUsage] {
        Array(monitor.usage.filter { $0.canQuit }.sorted { $0.memory > $1.memory }.prefix(6))
    }

    private struct HelperItem: Identifiable {
        let app: AppUsage
        let process: ProcessUsage
        var id: pid_t { process.pid }
    }

    private var helpers: [HelperItem] {
        let all = monitor.usage.flatMap { app in
            app.processes.filter { $0.canEnd && app.path != nil }.map { HelperItem(app: app, process: $0) }
        }
        return Array(all.sorted { $0.process.memory > $1.process.memory }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Free up memory").font(.title2.weight(.bold))
                Text(String(format: "%.1f of %.0f GB in use · ", monitor.memoryUsed / 1_073_741_824,
                            monitor.memoryTotal / 1_073_741_824) + pressureText)
                    .foregroundStyle(.secondary)
                Text("macOS fills spare memory on purpose and frees it the moment something needs it. What really frees memory is closing things you aren't using.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Apps using the most memory") {
                ForEach(apps) { app in
                    row(icon: AnyView(AppIcon(app: app, size: 20)), title: app.name,
                        detail: app.processes.count > 1 ? "\(app.processes.count) processes" : nil,
                        memory: app.memory, action: "Quit") { monitor.quit(app) }
                }
            }

            section("Heaviest pages and helpers") {
                ForEach(helpers) { item in
                    row(icon: AnyView(AppIcon(app: item.app, size: 20)), title: "\(item.app.name) · \(item.process.name)",
                        detail: item.process.name == "Web page" ? "reloads when you next look at it" : nil,
                        memory: item.process.memory, action: "End") { monitor.end(item.process) }
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clear file cache").font(.headline)
                    Text("This is what \u{201C}Free Up RAM\u{201D} buttons do. The memory graph drops for a while, but macOS would have reused that memory anyway, and apps may open a little slower until the cache fills again. Asks for your password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let r = cacheResult {
                        Text(r).font(.callout).foregroundStyle(.green)
                    }
                }
                Spacer()
                Button(clearing ? "Clearing…" : "Clear") {
                    clearing = true
                    let before = monitor.memoryUsed
                    monitor.clearFileCache { ok in
                        clearing = false
                        let freed = max(0, before - monitor.memoryUsed)
                        cacheResult = ok ? String(format: "Cleared. Memory in use went down by %.1f GB.", freed / 1_073_741_824)
                                         : "Not cleared (the password prompt was cancelled)."
                    }
                }
                .disabled(clearing)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private var pressureText: String {
        switch monitor.pressure {
        case .normal: return "memory pressure normal: nothing needs freeing"
        case .warning: return "memory pressure high"
        case .critical: return "memory pressure critical"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(icon: AnyView, title: String, detail: String?, memory: UInt64, action: String,
                     perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let d = detail { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(SystemMonitor.bytes(memory)).monospacedDigit().foregroundStyle(.secondary)
            Button(action) {
                NotchController.haptic(.generic)
                perform()
            }
            .frame(width: 60)
        }
    }
}

// MARK: - Cards and graphs

struct GraphSeries {
    let values: [Double]
    let colour: Color
    let fill: Bool
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let series: [GraphSeries]
    let range: ClosedRange<Double>?
    let selected: Bool
    var status: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashColour.secondary)
                    if let s = status {
                        Circle().fill(s).frame(width: 7, height: 7)
                    }
                    Spacer()
                    if series.count > 1 {
                        legend
                    }
                }
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DashColour.tertiary)
                    .lineLimit(2)
                    .frame(height: 30, alignment: .top)
                HistoryGraph(series: series, range: range)
                    .frame(height: 78)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hovering ? DashColour.cardHover : DashColour.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.35 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show the apps using the most \(title.lowercased())")
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem("Down", DashColour.down)
            legendItem("Up", DashColour.up)
        }
    }

    private func legendItem(_ text: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(colour).frame(width: 10, height: 3)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DashColour.tertiary)
        }
    }
}

/// The last few minutes as lines, newest on the right. `range` nil scales to the highest value.
struct HistoryGraph: View {
    let series: [GraphSeries]
    let range: ClosedRange<Double>?

    var body: some View {
        Canvas { ctx, size in
            // Faint guide lines
            for i in 1..<4 {
                let y = (size.height * CGFloat(i) / 4).rounded() + 0.5
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: y))
                guide.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(guide, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
            }

            let peak = series.flatMap { $0.values }.max() ?? 0
            let low = range?.lowerBound ?? 0
            let high = range?.upperBound ?? max(peak * 1.15, 0.000_001)
            let span = max(high - low, 0.000_001)
            let step = size.width / CGFloat(SystemHistory.capacity - 1)

            for s in series where s.values.count > 1 {
                var line = Path()
                var first = CGPoint.zero, last = CGPoint.zero
                for (i, v) in s.values.enumerated() {
                    let x = size.width - CGFloat(s.values.count - 1 - i) * step
                    let f = min(1, max(0, (v - low) / span))
                    let p = CGPoint(x: x, y: size.height * (1 - CGFloat(f)))
                    if i == 0 { line.move(to: p); first = p } else { line.addLine(to: p) }
                    last = p
                }
                if s.fill {
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [s.colour.opacity(0.32), s.colour.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                }
                ctx.stroke(line, with: .color(s.colour),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
