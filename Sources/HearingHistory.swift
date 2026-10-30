import SwiftUI
import AppKit
import Charts

// MARK: - One day of listening

struct HearingDay: Codable, Identifiable {
    var id: String { day }
    var day: String                                        // "2026-10-27"
    var seconds: Double = 0                                // time listened on headphones
    var energy: Double = 0                                 // Σ 10^(dB/10)·s, for the average
    var dose: Double = 0                                   // share of the weekly safe amount
    var peak: Double = 0
    var bands = [Double](repeating: 0, count: HearingBand.allCases.count)   // seconds in each band
    var hours = [Double](repeating: 0, count: 24)          // seconds listened in each hour
    var hourEnergy = [Double](repeating: 0, count: 24)

    init(day: String) { self.day = day }

    /// The average level, weighted the way loudness adds up (an "equivalent level")
    var average: Double? { seconds > 1 ? 10 * log10(energy / seconds) : nil }
    var date: Date { Self.formatter.date(from: day) ?? Date() }

    func hourAverage(_ h: Int) -> Double? {
        hours[h] > 1 ? 10 * log10(hourEnergy[h] / hours[h]) : nil
    }

    mutating func add(level: Double, seconds dt: Double, dose d: Double, hour: Int) {
        let e = pow(10, level / 10) * dt
        seconds += dt
        energy += e
        dose += d
        peak = max(peak, level)
        bands[HearingBand.of(level).rawValue] += dt
        if (0..<24).contains(hour) {
            hours[hour] += dt
            hourEnergy[hour] += e
        }
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ d: Date) -> String { formatter.string(from: d) }

    /// The keys of the last `n` days, oldest first, ending today
    static func lastDays(_ n: Int, from end: Date = Date()) -> [String] {
        (0..<n).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: end) }.map(key)
    }
}

enum HearingBand: Int, CaseIterable {
    case quiet, moderate, raised, loud, veryLoud

    static func of(_ level: Double) -> HearingBand {
        level < 70 ? .quiet : level < 80 ? .moderate : level < 85 ? .raised : level < 90 ? .loud : .veryLoud
    }

    var title: String {
        switch self {
        case .quiet: return "Under 70 dB"
        case .moderate: return "70–80 dB"
        case .raised: return "80–85 dB"
        case .loud: return "85–90 dB"
        case .veryLoud: return "Over 90 dB"
        }
    }

    var colour: Color {
        switch self {
        case .quiet: return Color(red: 0.32, green: 0.78, blue: 0.86)
        case .moderate: return Color(red: 0.36, green: 0.86, blue: 0.5)
        case .raised: return .yellow
        case .loud: return .orange
        case .veryLoud: return .red
        }
    }
}

// MARK: - The window

@MainActor
final class HearingWindow: NSObject, NSWindowDelegate {
    static let shared = HearingWindow()
    private var window: NSWindow?
    private var madeRegular = false

    func show() {
        HearingMonitor.shared.save()           // so the charts include the last few seconds
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
            madeRegular = true
        }
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: HearingHistoryView())
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Hearing"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.045, alpha: 1)
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 980, height: 760))
        w.minSize = NSSize(width: 820, height: 600)
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if madeRegular && NotchOnlyMode.isOn { NSApp.setActivationPolicy(.accessory) }
        madeRegular = false
        Task { @MainActor in self.window = nil }
    }
}

// MARK: - The view

private enum HearingRange: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month"
    var id: String { rawValue }
    var days: Int { self == .week ? 7 : 30 }
}

/// One stacked piece of a bar: a day, a loudness band, and the minutes spent in it
private struct BandSlice: Identifiable {
    let id = UUID()
    let date: Date
    let band: String
    let minutes: Double
}

private struct LevelPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let level: Double
}

private struct HourBar: Identifiable {
    var id: Int { hour }
    let hour: Int
    let minutes: Double
    let level: Double?
}

private struct WeekTotal: Identifiable {
    let id = UUID()
    let start: Date
    let hours: Double
    let dose: Double
}

struct HearingHistoryView: View {
    @ObservedObject private var monitor = HearingMonitor.shared
    @State private var range = HearingRange.week
    @State private var confirmClear = false

    private let card = Color.white.opacity(0.055)
    private let secondary = Color.white.opacity(0.55)

    var body: some View {
        // Redraws when the history is saved (every 30 s while listening), not continuously
        let _ = monitor.revision
        let days = monitor.days
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stats(days)
                HStack(alignment: .top, spacing: 14) {
                    timeChart(days)
                    levelChart(days)
                }
                HStack(alignment: .top, spacing: 14) {
                    weeksChart(days)
                    todayChart(days[HearingDay.key(Date())])
                }
                footnote
            }
            .padding(.horizontal, 32)
            .padding(.top, 38)
            .padding(.bottom, 26)
        }
        .background(Color(white: 0.045))
        .preferredColorScheme(.dark)
    }

    // MARK: Header and numbers

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hearing")
                    .font(.system(size: 28, weight: .bold))
                Text("Listening on headphones, with estimated levels")
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
            }
            Spacer()
            Picker("", selection: $range) {
                ForEach(HearingRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func stats(_ days: [String: HearingDay]) -> some View {
        let week = HearingDay.lastDays(7).compactMap { days[$0] }
        let previous = HearingDay.lastDays(7, from: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
            .compactMap { days[$0] }
        let time = week.reduce(0) { $0 + $1.seconds }
        let lastTime = previous.reduce(0) { $0 + $1.seconds }
        let energy = week.reduce(0) { $0 + $1.energy }
        let average = time > 1 ? 10 * log10(energy / time) : nil
        let dose = week.reduce(0) { $0 + $1.dose }
        let peak = week.map(\.peak).max() ?? 0

        return HStack(spacing: 14) {
            statCard("Listening this week", Self.duration(time),
                     lastTime > 60 ? change(time, lastTime) : "Last 7 days", colour: .white)
            statCard("Average level", average.map { "\(Int($0.rounded())) dB" } ?? "–",
                     average.map { $0 < 80 ? "Comfortable" : $0 < 85 ? "On the loud side" : "Loud" } ?? "No listening yet",
                     colour: average.map(HearingMonitor.colour) ?? .white)
            doseCard(dose)
            statCard("Loudest", peak > 0 ? "\(Int(peak.rounded())) dB" : "–", "This week",
                     colour: peak > 0 ? HearingMonitor.colour(peak) : .white)
        }
    }

    private func change(_ now: Double, _ before: Double) -> String {
        let diff = now - before
        let word = diff >= 0 ? "more" : "less"
        return "\(Self.duration(abs(diff))) \(word) than the week before"
    }

    private func statCard(_ title: String, _ value: String, _ detail: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(colour)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.4)).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(card))
    }

    private func doseCard(_ dose: Double) -> some View {
        let colour: Color = dose < 0.6 ? Color(red: 0.36, green: 0.86, blue: 0.5) : dose < 1 ? .yellow : .red
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0.001, dose))))
                    .stroke(colour, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((dose * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("Safe listening used").font(.system(size: 12, weight: .semibold)).foregroundStyle(secondary)
                Text(dose < 1 ? "Within the weekly guideline" : "Over the weekly guideline")
                    .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(card))
    }

    // MARK: Charts

    private func chartCard<Content: View>(_ title: String, _ subtitle: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.4))
            }
            content()
                .frame(height: 190)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(card))
    }

    /// Minutes per day, stacked by how loud it was
    private func timeChart(_ days: [String: HearingDay]) -> some View {
        var slices: [BandSlice] = []
        for key in HearingDay.lastDays(range.days) {
            let day = days[key] ?? HearingDay(day: key)
            for band in HearingBand.allCases {
                slices.append(BandSlice(date: day.date, band: band.title, minutes: day.bands[band.rawValue] / 60))
            }
        }
        return chartCard("Listening time", "Minutes per day, by how loud it was") {
            Chart(slices) { s in
                BarMark(x: .value("Day", s.date, unit: .day), y: .value("Minutes", s.minutes))
                    .foregroundStyle(by: .value("Level", s.band))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: HearingBand.allCases.map(\.title),
                                       range: HearingBand.allCases.map(\.colour))
            .chartLegend(position: .bottom, spacing: 8)
            .chartXAxis { dayAxis }
        }
    }

    /// The average level each day, against the 80 dB guideline
    private func levelChart(_ days: [String: HearingDay]) -> some View {
        let points: [LevelPoint] = HearingDay.lastDays(range.days).compactMap { days[$0] }.compactMap { d in
            d.average.map { LevelPoint(date: d.date, level: $0) }
        }
        return chartCard("Average level", "Per day; the dashed line is 80 dB, safe for 40 hours a week") {
            Chart {
                RuleMark(y: .value("Guideline", 80))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ForEach(points) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("dB", p.level))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("dB", p.level))
                        .foregroundStyle(HearingMonitor.colour(p.level))
                        .symbolSize(48)
                }
            }
            .chartYScale(domain: 50...100)
            .chartXScale(domain: (Calendar.current.date(byAdding: .day, value: -(range.days - 1),
                                                       to: Calendar.current.startOfDay(for: Date())) ?? Date())...Date())
            .chartXAxis { dayAxis }
            .overlay {
                if points.isEmpty { emptyNote }
            }
        }
    }

    /// Hours per week for the last 12 weeks, red when over the weekly guideline
    private func weeksChart(_ days: [String: HearingDay]) -> some View {
        let cal = Calendar.current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let weeks: [WeekTotal] = (0..<12).reversed().compactMap { back in
            guard let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek) else { return nil }
            let keys = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.map(HearingDay.key)
            let list = keys.compactMap { days[$0] }
            return WeekTotal(start: start, hours: list.reduce(0) { $0 + $1.seconds } / 3600,
                             dose: list.reduce(0) { $0 + $1.dose })
        }
        return chartCard("Time per week", "Hours on headphones, last 12 weeks; red weeks went over the guideline") {
            Chart(weeks) { w in
                BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Hours", w.hours))
                    .foregroundStyle(w.dose >= 1 ? Color.red : w.dose >= 0.6 ? Color.yellow
                                     : Color(red: 0.36, green: 0.86, blue: 0.5))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
        }
    }

    /// Today, hour by hour
    private func todayChart(_ today: HearingDay?) -> some View {
        let hours: [HourBar] = (0..<24).map { h in
            HourBar(hour: h, minutes: (today?.hours[h] ?? 0) / 60, level: today?.hourAverage(h))
        }
        return chartCard("Today", "Minutes in each hour, coloured by how loud it was") {
            Chart {
                ForEach(hours) { h in
                    BarMark(x: .value("Hour", h.hour), y: .value("Minutes", h.minutes))
                        .foregroundStyle(h.level.map(HearingMonitor.colour) ?? Color.white.opacity(0.2))
                        .cornerRadius(2)
                }
            }
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...60)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel {
                        if let h = v.as(Int.self) { Text(h == 23 ? "23h" : "\(h)h") }
                    }
                }
            }
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
            AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
        }
    }

    private var emptyNote: some View {
        Text("Listen on headphones and it fills in here")
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.4))
    }

    private var footnote: some View {
        HStack(alignment: .top) {
            Text("Levels are estimates from Visualiser (calibrate them in Settings › Extras). This tracks how much and how loud you listen, not your hearing itself: for that, AirPods Pro 2 and later can do Apple's Hearing Test on your iPhone (Settings › your AirPods › Take a Hearing Test). Kept on this Mac only.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)
            Button("Clear History…") { confirmClear = true }
                .confirmationDialog("Clear all listening history?", isPresented: $confirmClear) {
                    Button("Clear", role: .destructive) { HearingMonitor.shared.clearHistory() }
                }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return seconds > 0 ? "< 1 min" : "0 min" }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}
