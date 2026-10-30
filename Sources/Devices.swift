import SwiftUI
import IOBluetooth

/// What the island shows when a Bluetooth device connects or disconnects
struct DeviceInfo: Equatable {
    var name: String
    var symbol: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?
    var connected = true

    /// The lowest bud, which is the one that matters for "how long have I got"
    var headline: Int? {
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? single
    }
}

/// Watches Bluetooth devices connecting and disconnecting
final class BluetoothWatcher: NSObject {
    static let shared = BluetoothWatcher()

    var onConnect: ((IOBluetoothDevice) -> Void)?
    var onDisconnect: ((IOBluetoothDevice) -> Void)?
    private var note: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date.distantPast

    /// macOS requires this description before an app may use Bluetooth; without it, stay off
    static var allowed: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    func start() {
        guard note == nil, Self.allowed else { return }
        startedAt = Date()
        note = IOBluetoothDevice.register(forConnectNotifications: self,
                                          selector: #selector(connected(_:device:)))
    }

    func stop() {
        note?.unregister()
        note = nil
        for n in disconnectNotes.values { n.unregister() }
        disconnectNotes = [:]
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Watch every connected device for disconnecting, including ones already connected at launch
        let key = device.addressString ?? device.name ?? UUID().uuidString
        if disconnectNotes[key] == nil {
            disconnectNotes[key] = device.register(forDisconnectNotification: self,
                                                   selector: #selector(disconnected(_:device:)))
        }
        // Devices that were already connected are reported straight away; only announce new ones
        guard Date().timeIntervalSince(startedAt) > 2 else { return }
        onConnect?(device)
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? ""
        disconnectNotes[key]?.unregister()
        disconnectNotes[key] = nil
        onDisconnect?(device)
    }

    /// Name, icon and battery levels for any Bluetooth device
    static func info(for d: IOBluetoothDevice) -> DeviceInfo? {
        let name = d.name ?? "Bluetooth device"
        let lower = name.lowercased()
        let major = d.deviceClassMajor

        let symbol: String
        if name.contains("AirPods Pro") { symbol = "airpodspro" }
        else if name.contains("AirPods Max") { symbol = "airpodsmax" }
        else if name.contains("AirPods") { symbol = "airpods" }
        else if lower.contains("keyboard") { symbol = "keyboard" }
        else if lower.contains("mouse") { symbol = "magicmouse" }
        else if lower.contains("trackpad") { symbol = "rectangle.and.hand.point.up.left" }
        else if lower.contains("controller") || lower.contains("dualsense") || lower.contains("xbox") {
            symbol = "gamecontroller"
        }
        else if major == 0x04 {          // audio: headphones and speakers
            symbol = lower.contains("speaker") || lower.contains("boom") ? "hifispeaker" : "headphones"
        }
        else if major == 0x02 { symbol = "iphone" }            // phones
        else if major == 0x01 { symbol = "laptopcomputer" }    // computers
        else if major == 0x05 { symbol = "keyboard" }          // other input devices
        else { symbol = "dot.radiowaves.left.and.right" }

        return DeviceInfo(name: name, symbol: symbol,
                          left: battery(d, "batteryPercentLeft"),
                          right: battery(d, "batteryPercentRight"),
                          caseLevel: battery(d, "batteryPercentCase"),
                          single: battery(d, "batteryPercentSingle"))
    }

    /// Battery levels aren't public API, so only read them if this macOS version offers them
    private static func battery(_ d: IOBluetoothDevice, _ key: String) -> Int? {
        guard d.responds(to: NSSelectorFromString(key)),
              let v = (d.value(forKey: key) as? NSNumber)?.intValue, v > 0, v <= 100 else { return nil }
        return v
    }
}

// MARK: - The connect animation

struct DeviceActivityView: View {
    let info: DeviceInfo
    let notch: CGSize

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Ears: the device on the left, a battery ring on the right
            HStack {
                Image(systemName: info.symbol)
                    .font(.system(size: max(12, notch.height * 0.48), weight: .medium))
                    .foregroundStyle(info.connected ? Color.white : Color.white.opacity(0.45))
                    .symbolBounce(appeared)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .rotationEffect(.degrees(appeared ? 0 : -25))
                    .opacity(appeared ? 1 : 0)
                Spacer(minLength: 0)
                if !info.connected {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: max(12, notch.height * 0.45)))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .scaleEffect(appeared ? 1 : 0.3)
                } else if let level = info.headline {
                    BatteryRing(level: level, size: max(14, notch.height - 14), appeared: appeared)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: max(12, notch.height * 0.45)))
                        .foregroundStyle(Color.green)
                        .scaleEffect(appeared ? 1 : 0.3)
                }
            }
            .frame(height: notch.height)

            // Below the notch: the name and each part's battery
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(info.connected ? "Connected" : "Disconnected")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    if let l = info.left { level("L", l) }
                    if let r = info.right { level("R", r) }
                    if let c = info.caseLevel { level("Case", c) }
                    if info.left == nil && info.right == nil, let s = info.single { level("", s) }
                }
            }
            .padding(.top, 8)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : -6)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6).delay(0.12)) { appeared = true }
        }
    }

    private func level(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(value)%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BatteryRing.colour(value))
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .monospacedDigit()
    }
}

struct BatteryRing: View {
    let level: Int
    let size: CGFloat
    let appeared: Bool

    static func colour(_ level: Int) -> Color {
        level <= 10 ? .red : level <= 20 ? .orange : .green
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: appeared ? CGFloat(level) / 100 : 0)
                .stroke(Self.colour(level), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.9).delay(0.25), value: appeared)
        }
        .frame(width: size, height: size)
    }
}
