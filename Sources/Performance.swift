import SwiftUI
import AppKit
import IOKit.ps

// MARK: - Frame pacing
// The visuals redraw 60 times a second, or 30 to save energy. "Automatic" drops to 30 on battery
// and in Low Power Mode; 30 is hard to tell apart for most looks and costs about half as much.

@MainActor
final class FramePacing: ObservableObject {
    static let shared = FramePacing()
    @Published private(set) var interval: Double = 1.0 / 60

    private var timer: Timer?
    private var powerObserver: NSObjectProtocol?

    private init() {
        update()
        // Plugging in or unplugging is checked every 20 s; Low Power Mode announces itself
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in FramePacing.shared.update() }
        }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in FramePacing.shared.update() }
        }
    }

    /// "auto", "60" or "30"
    static var mode: String { UserDefaults.standard.string(forKey: "frameRate") ?? "auto" }

    var saving: Bool { interval > 1.0 / 45 }

    func update() {
        let saving: Bool
        switch Self.mode {
        case "60": saving = false
        case "30": saving = true
        default: saving = Self.onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        let new = saving ? 1.0 / 30 : 1.0 / 60
        if new != interval { interval = new }
    }

    static var onBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }
}

// MARK: - Is this window actually visible?
// A hidden, minimised or completely covered window doesn't need to be redrawn at all.
// Each visual checks its own window, so the wallpaper windows pause on their own too
// (for example while a full-screen app covers the desktop).

struct OnScreenReader: NSViewRepresentable {
    @Binding var onScreen: Bool

    func makeNSView(context: Context) -> OnScreenView {
        let view = OnScreenView()
        view.onChange = { visible in
            if onScreen != visible { onScreen = visible }
        }
        return view
    }

    func updateNSView(_ view: OnScreenView, context: Context) {
        view.onChange = { visible in
            if onScreen != visible { onScreen = visible }
        }
    }
}

final class OnScreenView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let w = window else {
            report(false)
            return
        }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            })
        }
        check()
    }

    private func check() {
        guard let w = window else { return report(false) }
        report(w.occlusionState.contains(.visible) && !w.isMiniaturized)
    }

    private func report(_ visible: Bool) {
        // After the current layout pass, since this changes SwiftUI state
        Task { @MainActor [weak self] in self?.onChange?(visible) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}
