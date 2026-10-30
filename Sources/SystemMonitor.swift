import AppKit
import Darwin
import IOKit
import IOKit.ps
import Network

// MARK: - What the monitor reports

/// One app (with all its helper processes) or one stand-alone process
struct AppUsage: Identifiable, Equatable {
    let id: String              // the app's path, or "proc:<name>" for processes outside an app
    let name: String
    let path: String?           // the .app bundle, when it is an app
    var cpu: Double             // percent, where 100 = one full core (like Activity Monitor)
    var memory: UInt64          // bytes
    var pids: [pid_t]
    var gpu: Double = 0         // 0...1 of the whole GPU
    var energy: Double = 0      // watts when macOS reports them, otherwise a relative score
    var down: Double = 0        // network, bytes per second
    var up: Double = 0
    var processes: [ProcessUsage] = []   // the app itself and every helper it's responsible for

    var runningApp: NSRunningApplication? {
        guard let p = path else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == p }
    }

    /// Ordinary apps with a Dock icon can be quit from here (Safari included, even though it now
    /// lives in a system folder); never this app, the Finder or macOS's own background parts
    var canQuit: Bool {
        guard let p = path, p != Bundle.main.bundlePath, let app = runningApp else { return false }
        return app.activationPolicy == .regular && app.bundleIdentifier != "com.apple.finder"
    }
}

/// One process within an app: the app itself, or a helper such as one website in Safari
struct ProcessUsage: Identifiable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    var cpu: Double
    var memory: UInt64
    let isMain: Bool

    /// Helpers can be ended on their own (a website in Safari reloads; most helpers restart by
    /// themselves). The app's own main process is quit with Quit instead.
    var canEnd: Bool { !isMain && pid > 1 }

    /// A friendlier name for the common helpers
    static func displayName(_ raw: String) -> String {
        switch raw {
        case "com.apple.WebKit.WebContent", "Safari Web Content": return "Web page"
        case "com.apple.WebKit.Networking": return "Networking"
        case "com.apple.WebKit.GPU": return "Graphics"
        default:
            if raw.hasSuffix(" Helper (Renderer)") { return "Page or tab" }
            if raw.hasSuffix(" Helper (GPU)") { return "Graphics" }
            if raw.hasSuffix(" Helper (Plugin)") { return "Plug-in" }
            if raw.hasSuffix(" Helper") { return "Helper" }
            return raw
        }
    }
}

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var minutesLeft: Int?
    var health: Int?            // maximum capacity, as a percentage of new
    var cycles: Int?
}

/// What the app list is sorted by
enum UsageCategory: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, energy, network
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .energy: return "Energy"
        case .network: return "Network"
        }
    }

    var heading: String {
        switch self {
        case .cpu: return "Using the most CPU"
        case .gpu: return "Using the most GPU"
        case .memory: return "Using the most memory"
        case .energy: return "Using the most energy"
        case .network: return "Using the network"
        }
    }

    func value(_ a: AppUsage) -> Double {
        switch self {
        case .cpu: return a.cpu
        case .gpu: return a.gpu
        case .memory: return Double(a.memory)
        case .energy: return a.energy
        case .network: return a.down + a.up
        }
    }
}

/// Which gauge is picked in the System tab (temperature lists the apps making the heat: energy)
enum SystemPick: String, CaseIterable {
    case cpu, gpu, memory, temp, energy, network
    var category: UsageCategory {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .temp, .energy: return .energy
        case .network: return .network
        }
    }
}

struct NetworkStatus: Equatable {
    enum Link: Equatable { case unknown, offline, wifi, ethernet, hotspot, other }
    var link: Link = .unknown
    var internet: Bool?         // nil until checked
    var down: Double = 0        // bytes per second, all Wi-Fi and Ethernet together
    var up: Double = 0

    var linkName: String {
        switch link {
        case .unknown: return "Network"
        case .offline: return "Offline"
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .hotspot: return "Hotspot"
        case .other: return "Connected"
        }
    }

    /// "Wi-Fi · Internet connected", "Wi-Fi · No internet", "Offline"
    var summary: String {
        if link == .offline { return "Offline" }
        switch internet {
        case true?: return "\(linkName) · Internet connected"
        case false?: return "\(linkName) · No internet"
        case nil: return "\(linkName) · Checking…"
        }
    }
}

/// The last few minutes of each reading, for the graphs
struct SystemHistory {
    static let capacity = 240
    var cpu: [Double] = []
    var gpu: [Double] = []
    var memory: [Double] = []       // fraction of RAM
    var temp: [Double] = []         // °C
    var energy: [Double] = []       // total of the apps' energy
    var down: [Double] = []
    var up: [Double] = []

    static func add(_ v: Double, to list: inout [Double]) {
        list.append(v)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
    }
}

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4
}

struct SystemAlert: Equatable {
    enum Kind: Equatable { case cpu, memory, battery, heat, notResponding }
    let kind: Kind
    let title: String
    let subtitle: String
    let value: String           // the big number in the right ear, e.g. "143%"
    let symbol: String
    let appID: String?
    let appPath: String?
}

// MARK: - The monitor

final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpu: Double = 0             // 0...1 of the whole chip
    @Published private(set) var gpu: Double?                // 0...1
    @Published private(set) var memoryUsed: Double = 0      // bytes, counted like Activity Monitor
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var pressure: MemoryPressure = .normal
    @Published private(set) var temperature: Double?        // °C, if this Mac's sensors can be read
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var apps: [AppUsage] = []       // heaviest CPU users first
    @Published private(set) var usage: [AppUsage] = []      // every app and process, unsorted
    @Published private(set) var network = NetworkStatus()
    @Published private(set) var history = SystemHistory()
    @Published private(set) var energyInWatts = false       // false: a relative score instead
    @Published private(set) var gpuPerApp = false           // this Mac reports GPU time per app
    @Published private(set) var networkPerApp = false       // per-app network has been measured
    /// The gauge picked in the island or the full-screen view (shared, so they agree)
    @Published var pick: SystemPick = .cpu {
        didSet { if pick == .network && detail { sampleAppNetwork() } }
    }

    /// Called when something needs your attention
    var onAlert: ((SystemAlert) -> Void)?

    private var timer: Timer?
    private var islandDetail = false
    private var dashboardOpen = false
    private var alerts = false
    private var detail: Bool { islandDetail || dashboardOpen }
    private var lastEnergy: [pid_t: UInt64] = [:]
    private var lastWakeups: [pid_t: UInt64] = [:]
    private var lastGPUTime: [pid_t: UInt64] = [:]
    private var lastInterfaces: [String: (down: UInt32, up: UInt32)] = [:]
    private var lastInterfaceTime: Date?
    private var lastNetBytes: [pid_t: (down: UInt64, up: UInt64)] = [:]
    private var lastNetTime: Date?
    private var netRates: [pid_t: (down: Double, up: Double)] = [:]
    private var nettopRunning = false
    private var pathMonitor: NWPathMonitor?
    private var lastInternetCheck = Date.distantPast
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var identities: [pid_t: (key: String, name: String, path: String?)] = [:]
    private var lastSample = Date()
    private let timebase: Double
    private let temps = TemperatureReader()

    // Alert bookkeeping
    private var heavySince: [String: Date] = [:]
    private var quietUntil: [String: Date] = [:]
    private var pressureSince: Date?
    private var batteryWarned: Set<Int> = []
    private var heatWarned = false

    private init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = Double(tb.numer) / Double(tb.denom)
    }

    /// `detail`: the System tab is open (sample everything, every 2 s).
    /// `alerts`: watch in the background for problems (every 5 s, skipping GPU and temperature).
    func update(detail: Bool, alerts: Bool) {
        islandDetail = detail
        self.alerts = alerts
        reschedule()
    }

    /// The full-screen view samples every second while it's open
    func setDashboard(_ open: Bool) {
        dashboardOpen = open
        reschedule()
    }

    private var lastLogged = Date.distantPast

    private func reschedule() {
        let wasRunning = timer != nil
        guard detail || alerts || UsageLog.enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        let interval: TimeInterval = dashboardOpen ? 1 : islandDetail ? 2 : 5
        if timer?.timeInterval != interval {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.sample()
            }
        }
        if detail { startPathMonitor() }
        if detail || !wasRunning {
            // Two quick samples, so CPU figures (which need a before and after) appear straight away
            sample()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.sample() }
        }
    }

    // MARK: Quitting

    func quit(_ app: AppUsage) {
        guard app.canQuit, let running = app.runningApp else { return }
        running.terminate()
        // If it's still there after a few seconds, offer to force it
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard !running.isTerminated else { return }
            self?.onAlert?(SystemAlert(kind: .notResponding,
                                       title: "\(app.name) didn't quit",
                                       subtitle: "It may be busy or have unsaved work. Force quit loses unsaved changes.",
                                       value: "", symbol: "exclamationmark.triangle.fill",
                                       appID: app.id, appPath: app.path))
        }
    }

    /// Ends one helper process (a website in Safari reloads when you next look at it)
    func end(_ process: ProcessUsage) {
        guard process.canEnd else { return }
        kill(process.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.sample() }
    }

    /// Empties macOS's file cache (what "Free Up RAM" buttons do). Asks for your password.
    /// It mostly makes the memory graph look better for a while: macOS reuses that memory anyway.
    func clearFileCache(done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")
            script?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                self.sample()
                done(error == nil)
            }
        }
    }

    func forceQuit(path: String?) {
        guard let p = path,
              let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == p })
        else { return }
        running.forceTerminate()
    }

    /// Stops warning about this app for a while
    func snooze(_ id: String?, minutes: Double) {
        guard let id = id else { return }
        quietUntil[id] = Date().addingTimeInterval(minutes * 60)
        heavySince[id] = nil
    }

    /// Never warns about this app again (until removed in Settings)
    func ignoreForever(_ id: String?) {
        guard let id = id else { return }
        var list = UserDefaults.standard.stringArray(forKey: "ignoredApps") ?? []
        if !list.contains(id) { list.append(id) }
        UserDefaults.standard.set(list, forKey: "ignoredApps")
    }

    // MARK: Sampling

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleProcesses()
        battery = Self.readBattery()
        thermal = ProcessInfo.processInfo.thermalState
        if detail {
            gpu = Self.readGPU()
            temperature = temps.read()
            sampleGPUApps()
            sampleNetwork()
            if pick == .network || dashboardOpen { sampleAppNetwork() }
            if Date().timeIntervalSince(lastInternetCheck) > 20 { checkInternet() }
            record()
        }
        if alerts { checkAlerts() }
        if UsageLog.enabled, Date().timeIntervalSince(lastLogged) >= 60 {
            lastLogged = Date()
            UsageLog.shared.record(apps: usage, memoryUsed: memoryUsed, pressure: pressure, cpu: cpu)
        }
    }

    private func record() {
        var h = history
        SystemHistory.add(cpu, to: &h.cpu)
        SystemHistory.add(gpu ?? 0, to: &h.gpu)
        SystemHistory.add(memoryUsed / memoryTotal, to: &h.memory)
        if let t = temperature { SystemHistory.add(t, to: &h.temp) }
        SystemHistory.add(usage.reduce(0.0) { $0 + $1.energy }, to: &h.energy)
        SystemHistory.add(network.down, to: &h.down)
        SystemHistory.add(network.up, to: &h.up)
        history = h
    }

    /// The heaviest apps for one category
    func top(_ category: UsageCategory, _ count: Int) -> [AppUsage] {
        let list = usage.filter { category == .memory || category.value($0) > 0.0001 }
        return Array(list.sorted { category.value($0) > category.value($1) }.prefix(count))
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        if let last = lastTicks, total > last.total {
            cpu = min(1, max(0, Double(busy - last.busy) / Double(total - last.total)))
        }
        lastTicks = (busy, total)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let appMemory = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            memoryUsed = (appMemory + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
    }

    private func sampleProcesses() {
        let now = Date()
        let seconds = max(0.2, now.timeIntervalSince(lastSample))
        lastSample = now

        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard found > 0 else { return }

        var groups: [String: AppUsage] = [:]
        var seen: [pid_t: UInt64] = [:]
        let mainPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        var newEnergy: [pid_t: UInt64] = [:]
        var newWakeups: [pid_t: UInt64] = [:]
        var wakeScore: [String: Double] = [:]
        for pid in pids.prefix(found) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }      // other users' processes can't be read; that's fine

            // CPU time comes in machine ticks on Apple silicon; convert to nanoseconds
            let cpuNs = UInt64(Double(info.ri_user_time + info.ri_system_time) * timebase)
            seen[pid] = cpuNs
            var percent = 0.0
            if let before = lastCPUTime[pid], cpuNs > before {
                percent = Double(cpuNs - before) / (seconds * 1e9) * 100
            }

            // Energy macOS has charged to this process (nanojoules), and how often it wakes the chip
            let energy = info.ri_billed_energy
            let wakeups = info.ri_pkg_idle_wkups + info.ri_interrupt_wkups
            var watts = 0.0, wakeRate = 0.0
            if let before = lastEnergy[pid], energy >= before { watts = Double(energy - before) / seconds / 1e9 }
            if let before = lastWakeups[pid], wakeups >= before { wakeRate = Double(wakeups - before) / seconds }
            newEnergy[pid] = energy
            newWakeups[pid] = wakeups

            let who = identity(pid)
            var group = groups[who.key] ?? AppUsage(id: who.key, name: who.name, path: who.path,
                                                    cpu: 0, memory: 0, pids: [])
            group.cpu += percent
            group.memory += info.ri_phys_footprint
            group.pids.append(pid)
            group.processes.append(ProcessUsage(pid: pid, name: cachedName(pid), cpu: percent,
                                                memory: info.ri_phys_footprint,
                                                isMain: mainPIDs.contains(pid)))
            group.energy += watts
            wakeScore[who.key, default: 0] += percent + wakeRate * 0.05
            if let rate = netRates[pid] {
                group.down += rate.down
                group.up += rate.up
            }
            groups[who.key] = group
        }
        lastCPUTime = seen
        lastEnergy = newEnergy
        lastWakeups = newWakeups
        identities = identities.filter { seen[$0.key] != nil }
        names = names.filter { seen[$0.key] != nil }

        // Real watts when the numbers look like watts; otherwise a score like Activity Monitor's
        let totalWatts = groups.values.reduce(0.0) { $0 + $1.energy }
        let watts = totalWatts > 0.02 && totalWatts < 200
        if !watts {
            for key in groups.keys { groups[key]?.energy = wakeScore[key] ?? 0 }
        }
        energyInWatts = watts

        // Network for processes we can't read otherwise (other users' daemons)
        for (pid, rate) in netRates where seen[pid] == nil {
            let who = identity(pid)
            var group = groups[who.key] ?? AppUsage(id: who.key, name: who.name, path: who.path,
                                                    cpu: 0, memory: 0, pids: [pid])
            group.down += rate.down
            group.up += rate.up
            groups[who.key] = group
        }

        // GPU time per app, measured separately (some of it belongs to processes we can't read)
        for (pid, share) in gpuShares {
            let who = identity(pid)
            var group = groups[who.key] ?? AppUsage(id: who.key, name: who.name, path: who.path,
                                                    cpu: 0, memory: 0, pids: [pid])
            group.gpu += share
            groups[who.key] = group
        }

        usage = Array(groups.values)
        apps = Array(groups.values.sorted { $0.cpu > $1.cpu }.prefix(12))
    }

    // MARK: GPU per app
    // Each app talking to the GPU has a client entry under the GPU in the I/O registry, with the
    // GPU time it has used. Its share of all that time, times the GPU's busyness, is its GPU use.

    private var gpuShares: [pid_t: Double] = [:]

    private func sampleGPUApps() {
        let times = Self.readGPUClients()
        gpuPerApp = !times.isEmpty
        var deltas: [pid_t: Double] = [:]
        for (pid, t) in times {
            if let before = lastGPUTime[pid], t > before { deltas[pid] = Double(t - before) }
        }
        lastGPUTime = times
        let total = deltas.values.reduce(0, +)
        let busy = gpu ?? 0
        gpuShares = total > 0 ? deltas.mapValues { $0 / total * busy } : [:]
        // Fold the fresh numbers into the current list straight away
        if !gpuShares.isEmpty || usage.contains(where: { $0.gpu > 0 }) {
            var byKey: [String: Double] = [:]
            for (pid, share) in gpuShares { byKey[identity(pid).key, default: 0] += share }
            usage = usage.map { var a = $0; a.gpu = byKey[a.id] ?? 0; return a }
        }
    }

    static func readGPUClients() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    var props: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let dict = props?.takeRetainedValue() as? [String: Any],
                       let creator = dict["IOUserClientCreator"] as? String,     // "pid 123, Safari"
                       let usage = dict["AppUsage"] as? [[String: Any]] {
                        let words = creator.split(separator: ",").first?.split(separator: " ") ?? []
                        if words.count == 2, words[0] == "pid", let pid = pid_t(words[1]) {
                            let time = usage.reduce(UInt64(0)) {
                                $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
                            }
                            result[pid, default: 0] += time
                        }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(iterator)
        }
        return result
    }

    // MARK: Network

    /// Whole-Mac download and upload, from the Wi-Fi and Ethernet counters
    private func sampleNetwork() {
        let now = Date()
        let current = Self.interfaceCounters()
        if let last = lastInterfaceTime {
            let dt = max(0.2, now.timeIntervalSince(last))
            var down = 0.0, up = 0.0
            for (name, c) in current {
                guard let before = lastInterfaces[name] else { continue }
                // The counters are 32-bit and wrap around at 4 GB; wrapping subtraction handles that
                down += Double(c.down &- before.down)
                up += Double(c.up &- before.up)
            }
            network.down = down / dt
            network.up = up / dt
        }
        lastInterfaces = current
        lastInterfaceTime = now
    }

    static func interfaceCounters() -> [String: (down: UInt32, up: UInt32)] {
        var result: [String: (down: UInt32, up: UInt32)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let a = entry.pointee
            if let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data {
                let name = String(cString: a.ifa_name)
                if name.hasPrefix("en") {          // Wi-Fi and Ethernet; skips VPN tunnels (counted twice)
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    result[name] = (d.ifi_ibytes, d.ifi_obytes)
                }
            }
            cursor = a.ifa_next
        }
        return result
    }

    /// Network per app comes from macOS's own `nettop`, run once per sample in the background
    private func sampleAppNetwork() {
        guard !nettopRunning else { return }
        nettopRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Self.runNettop()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.nettopRunning = false
                guard let rows = rows else { return }
                let now = Date()
                var rates: [pid_t: (down: Double, up: Double)] = [:]
                if let last = self.lastNetTime {
                    let dt = max(0.3, now.timeIntervalSince(last))
                    for (pid, b) in rows {
                        if let before = self.lastNetBytes[pid], b.down >= before.down, b.up >= before.up {
                            let r = (down: Double(b.down - before.down) / dt, up: Double(b.up - before.up) / dt)
                            if r.down > 0 || r.up > 0 { rates[pid] = r }
                        }
                    }
                    self.networkPerApp = true
                }
                self.lastNetBytes = rows
                self.lastNetTime = now
                self.netRates = rates

                // Show the new rates straight away rather than at the next sample
                var byKey: [String: (Double, Double)] = [:]
                for (pid, r) in rates {
                    let key = self.identity(pid).key
                    let old = byKey[key] ?? (0, 0)
                    byKey[key] = (old.0 + r.down, old.1 + r.up)
                }
                var list = self.usage.map { a -> AppUsage in
                    var a = a
                    a.down = byKey[a.id]?.0 ?? 0
                    a.up = byKey[a.id]?.1 ?? 0
                    return a
                }
                // Processes we can't otherwise read (other users' daemons) still show up here
                let known = Set(list.map(\.id))
                for (pid, r) in rates {
                    let who = self.identity(pid)
                    guard !known.contains(who.key), !list.contains(where: { $0.id == who.key }) else { continue }
                    let total = byKey[who.key] ?? (r.down, r.up)
                    list.append(AppUsage(id: who.key, name: who.name, path: who.path, cpu: 0, memory: 0,
                                         pids: [pid], down: total.0, up: total.1))
                }
                self.usage = list
            }
        }
    }

    static func runNettop() -> [pid_t: (down: UInt64, up: UInt64)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // One sample, one line per process, raw byte counts: "time,name.pid,bytes_in,bytes_out,"
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var result: [pid_t: (down: UInt64, up: UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, let dot = fields[1].lastIndex(of: "."),
                  let pid = pid_t(fields[1][fields[1].index(after: dot)...]),
                  let down = UInt64(fields[2].trimmingCharacters(in: .whitespaces)),
                  let up = UInt64(fields[3].trimmingCharacters(in: .whitespaces)) else { continue }
            let old = result[pid] ?? (0, 0)
            result[pid] = (old.down + down, old.up + up)
        }
        return result.isEmpty ? nil : result
    }

    /// Wi-Fi or Ethernet, from macOS; then whether the internet itself answers
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if path.status != .satisfied {
                    self.network.link = .offline
                    self.network.internet = false
                } else if path.usesInterfaceType(.wifi) {
                    self.network.link = path.isExpensive ? .hotspot : .wifi
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.network.link = .ethernet
                } else {
                    self.network.link = path.isExpensive ? .hotspot : .other
                }
                self.checkInternet()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private static let probe = URLSession(configuration: .ephemeral)

    private func checkInternet() {
        lastInternetCheck = Date()
        guard network.link != .offline else { network.internet = false; return }
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        Self.probe.dataTask(with: request) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { self?.network.internet = ok }
        }.resume()
    }

    /// Groups helpers with their app: "Google Chrome Helper (Renderer)" counts as Google Chrome
    /// Which app a process belongs to. macOS keeps a "responsible process" for every helper
    /// (it's how Activity Monitor knows a WebKit process is Safari's), so helpers that live outside
    /// the app's folder still count towards the right app.
    private func identity(_ pid: pid_t) -> (key: String, name: String, path: String?) {
        if let known = identities[pid] { return known }
        let own = rawIdentity(pid)
        var result = own
        if own.path == nil || own.key.hasPrefix("proc:"),
           let responsible = Self.responsiblePID(pid), responsible > 1, responsible != pid {
            let owner = rawIdentity(responsible)
            if owner.path != nil { result = owner }
        }
        identities[pid] = result
        return result
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        // RTLD_DEFAULT: look the function up in what's already loaded (it's part of libSystem)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let f = responsibleFunction else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    private var names: [pid_t: String] = [:]

    private func cachedName(_ pid: pid_t) -> String {
        if let n = names[pid] { return n }
        let n = Self.processName(pid)
        names[pid] = n
        return n
    }

    static func processName(_ pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        if !name.isEmpty { return ProcessUsage.displayName(name) }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
            ? ProcessUsage.displayName((String(cString: buffer) as NSString).lastPathComponent)
            : "Process \(pid)"
    }

    private func rawIdentity(_ pid: pid_t) -> (key: String, name: String, path: String?) {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let full = length > 0 ? String(cString: buffer) : ""

        let result: (key: String, name: String, path: String?)
        if let range = full.range(of: ".app/") {
            let appPath = String(full[..<range.lowerBound]) + ".app"
            let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            result = (appPath, name, appPath)
        } else {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer).isEmpty ? (full as NSString).lastPathComponent
                                                           : String(cString: nameBuffer)
            result = ("proc:" + name, name.isEmpty ? "Process \(pid)" : name, nil)
        }
        return result
    }

    // MARK: Alerts

    private func checkAlerts() {
        let d = UserDefaults.standard
        let now = Date()
        let ignored = Set(d.stringArray(forKey: "ignoredApps") ?? [])

        // An app that stays heavy, not a short spike
        if d.object(forKey: "sysAlertCPU") as? Bool ?? true {
            let threshold = d.object(forKey: "sysCPUThreshold") as? Double ?? 80
            let duration = d.object(forKey: "sysCPUDuration") as? Double ?? 60
            var stillHeavy = Set<String>()
            for app in apps where app.canQuit && !ignored.contains(app.id) && app.cpu >= threshold {
                stillHeavy.insert(app.id)
                let since = heavySince[app.id] ?? now
                heavySince[app.id] = since
                if now.timeIntervalSince(since) >= duration, (quietUntil[app.id] ?? .distantPast) < now {
                    quietUntil[app.id] = now.addingTimeInterval(15 * 60)
                    let minutes = Int(now.timeIntervalSince(since) / 60)
                    onAlert?(SystemAlert(kind: .cpu,
                                         title: "\(app.name) is working hard",
                                         subtitle: minutes >= 1 ? "High CPU use for over \(minutes) min"
                                                                : "High CPU use for the last minute",
                                         value: "\(Int(app.cpu.rounded()))%",
                                         symbol: "cpu", appID: app.id, appPath: app.path))
                    break
                }
            }
            heavySince = heavySince.filter { stillHeavy.contains($0.key) }
        }

        // Memory under real pressure for half a minute: point at the biggest app
        if d.object(forKey: "sysAlertMemory") as? Bool ?? true {
            if pressure == .critical {
                let since = pressureSince ?? now
                pressureSince = since
                if now.timeIntervalSince(since) >= 30, (quietUntil["memory"] ?? .distantPast) < now {
                    quietUntil["memory"] = now.addingTimeInterval(30 * 60)
                    let biggest = apps.filter { $0.canQuit && !ignored.contains($0.id) }
                        .max { $0.memory < $1.memory }
                    onAlert?(SystemAlert(kind: .memory,
                                         title: "Memory is running low",
                                         subtitle: biggest.map { "\($0.name) is using \(Self.bytes($0.memory))" }
                                             ?? "Quitting an app you aren't using will help",
                                         value: "",
                                         symbol: "memorychip", appID: biggest?.id, appPath: biggest?.path))
                }
            } else {
                pressureSince = nil
            }
        }

        // Low battery, once at 20% and once at 10%, while running on battery
        if d.object(forKey: "sysAlertBattery") as? Bool ?? true, let b = battery {
            if b.pluggedIn {
                batteryWarned = []
            } else {
                for level in [10, 20] where b.percent <= level && !batteryWarned.contains(level) {
                    batteryWarned.formUnion([10, 20].filter { $0 >= level })
                    onAlert?(SystemAlert(kind: .battery,
                                         title: "Battery low",
                                         subtitle: b.minutesLeft.map { "About \(Self.duration($0)) left" }
                                             ?? "Plug in your Mac soon",
                                         value: "\(b.percent)%",
                                         symbol: level == 10 ? "battery.0percent" : "battery.25percent",
                                         appID: nil, appPath: nil))
                    break
                }
            }
        }

        // Running hot
        if d.object(forKey: "sysAlertHeat") as? Bool ?? true {
            let hot = thermal == .serious || thermal == .critical
            if hot && !heatWarned {
                heatWarned = true
                let top = apps.first { $0.canQuit && !ignored.contains($0.id) }
                onAlert?(SystemAlert(kind: .heat,
                                     title: "Your Mac is running hot",
                                     subtitle: top.map { "\($0.name) is the busiest app right now" }
                                         ?? "macOS may slow things down to cool off",
                                     value: temperature.map { "\(Int($0))°" } ?? "",
                                     symbol: "thermometer.high", appID: top?.id, appPath: top?.path))
            } else if !hot {
                heatWarned = false
            }
        }
    }

    // MARK: Formatting

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : "\(Int(Double(b) / 1_048_576)) MB"
    }

    /// "1.2 MB/s", "340 KB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b >= 1_000_000 { return String(format: b >= 10_000_000 ? "%.0f MB/s" : "%.1f MB/s", b / 1_000_000) }
        return "\(Int((b / 1000).rounded())) KB/s"
    }

    /// "1.2M", "340K" for small spaces
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b >= 1_000_000 { return String(format: b >= 10_000_000 ? "%.0fM" : "%.1fM", b / 1_000_000) }
        return "\(Int((b / 1000).rounded()))K"
    }

    /// Watts when they're real watts, otherwise the relative score
    func energyText(_ value: Double) -> String {
        guard energyInWatts else { return String(format: "%.1f", value) }
        return value >= 1 ? String(format: "%.1f W", value) : "\(Int((value * 1000).rounded())) mW"
    }

    /// The two numbers shown beside an app for a category
    func columns(_ app: AppUsage, _ category: UsageCategory) -> (String, String) {
        let cpuText = "\(Int(app.cpu.rounded()))%"
        switch category {
        case .cpu: return (cpuText, Self.bytes(app.memory))
        case .gpu: return ("\(Int((app.gpu * 100).rounded()))%", cpuText)
        case .memory: return (Self.bytes(app.memory), cpuText)
        case .energy: return (energyText(app.energy), cpuText)
        case .network: return ("↓ " + Self.rate(app.down), "↑ " + Self.rate(app.up))
        }
    }

    static func columnTitles(_ category: UsageCategory) -> (String, String) {
        switch category {
        case .cpu: return ("CPU", "Memory")
        case .gpu: return ("GPU", "CPU")
        case .memory: return ("Memory", "CPU")
        case .energy: return ("Energy", "CPU")
        case .network: return ("Down", "Up")
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    // MARK: GPU (Apple silicon reports its own utilisation)

    static func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                result = max(result ?? 0, min(1, util / 100))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    // MARK: Battery

    static func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = desc[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = (charging ? desc[kIOPSTimeToFullChargeKey] : desc[kIOPSTimeToEmptyKey]) as? Int
            var info = BatteryInfo(percent: current * 100 / maximum, charging: charging, pluggedIn: plugged,
                                   minutesLeft: (minutes ?? -1) > 0 ? minutes : nil, health: nil, cycles: nil)

            // Health and cycle count live on the battery's own entry in the I/O registry
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    info.cycles = dict["CycleCount"] as? Int
                    let design = dict["DesignCapacity"] as? Int
                    let full = (dict["AppleRawMaxCapacity"] as? Int) ?? (dict["NominalChargeCapacity"] as? Int)
                    if let d = design, let f = full, d > 0 { info.health = min(100, f * 100 / d) }
                }
            }
            return info
        }
        return nil
    }
}

// MARK: - Temperature
// Apple silicon has no public temperature API. This reads the chip's own sensors the way stats
// apps do, through parts of IOKit Apple doesn't document. If a macOS update changes them,
// it simply returns nil and the app falls back to macOS's heat level (normal / warm / hot).

final class TemperatureReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatching = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloat = @convention(c) (OpaquePointer, Int32) -> Double

    private var client: OpaquePointer?
    private var copyServices: CopyServices?
    private var copyProperty: CopyProperty?
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(h, "IOHIDEventSystemClientCreate"),
              let match = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let services = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let property = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let event = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let float = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        copyServices = unsafeBitCast(services, to: CopyServices.self)
        copyProperty = unsafeBitCast(property, to: CopyProperty.self)
        copyEvent = unsafeBitCast(event, to: CopyEvent.self)
        getFloat = unsafeBitCast(float, to: GetFloat.self)
        guard let c = unsafeBitCast(create, to: CreateClient.self)(kCFAllocatorDefault) else { return }
        // Vendor usage page 0xff00, usage 5: the temperature sensors
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(match, to: SetMatching.self)(c, matching)
        client = c
    }

    /// The hottest CPU die sensor, in °C
    func read() -> Double? {
        guard let c = client, let copyServices = copyServices, let copyProperty = copyProperty,
              let copyEvent = copyEvent, let getFloat = getFloat,
              let services = copyServices(c)?.takeRetainedValue() as? [AnyObject] else { return nil }

        let temperatureEvent: Int64 = 15
        let field = Int32(15 << 16)
        var dies: [Double] = []
        var all: [Double] = []
        for service in services {
            let ref = OpaquePointer(Unmanaged.passUnretained(service).toOpaque())
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard let event = copyEvent(ref, temperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, field)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            guard value > 10, value < 130 else { continue }
            all.append(value)
            if name.lowercased().contains("tdie") { dies.append(value) }
        }
        let pick = dies.isEmpty ? all : dies
        return pick.max()
    }
}
