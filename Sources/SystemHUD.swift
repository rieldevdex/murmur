import AppKit
import CoreAudio
import AudioToolbox
import ApplicationServices

// MARK: - System volume (Core Audio, no permission needed)

enum SystemVolume {
    static func outputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultDeviceAddress
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 0...1, or nil if the current output (e.g. some HDMI displays) has no volume control
    static func volume() -> Float? {
        guard let d = outputDevice() else { return nil }
        var addr = volumeAddress
        guard AudioObjectHasProperty(d, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ value: Float) {
        guard let d = outputDevice() else { return }
        var addr = volumeAddress
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted() -> Bool {
        guard let d = outputDevice() else { return false }
        var addr = muteAddress
        guard AudioObjectHasProperty(d, &addr) else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let d = outputDevice() else { return }
        var addr = muteAddress
        guard AudioObjectHasProperty(d, &addr) else { return }
        var m = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    /// Nudges the volume, unmuting first, the way the volume keys do
    static func step(_ amount: Float) {
        guard let v = volume() else { return }
        if isMuted() && amount > 0 { setMuted(false) }
        setVolume(v + amount)
    }
}

/// Calls back whenever the system volume or mute changes, from the keys, Control Centre or any app
final class VolumeWatcher {
    var onChange: ((Float, Bool) -> Void)?

    private var device: AudioDeviceID = 0
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebind() }
        deviceBlock = changed
        var addr = SystemVolume.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, changed)
        rebind()
    }

    func stop() {
        guard running else { return }
        running = false
        unbind()
        if let b = deviceBlock {
            var addr = SystemVolume.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, b)
        }
        deviceBlock = nil
    }

    /// Follow the output device when it changes, e.g. when AirPods connect
    private func rebind() {
        unbind()
        guard let d = SystemVolume.outputDevice() else { return }
        device = d
        let report: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let v = SystemVolume.volume() else { return }
            self?.onChange?(v, SystemVolume.isMuted())
        }
        volumeBlock = report
        var vol = SystemVolume.volumeAddress
        var mute = SystemVolume.muteAddress
        AudioObjectAddPropertyListenerBlock(d, &vol, .main, report)
        if AudioObjectHasProperty(d, &mute) { AudioObjectAddPropertyListenerBlock(d, &mute, .main, report) }
    }

    private func unbind() {
        guard device != 0, let b = volumeBlock else { return }
        var vol = SystemVolume.volumeAddress
        var mute = SystemVolume.muteAddress
        AudioObjectRemovePropertyListenerBlock(device, &vol, .main, b)
        AudioObjectRemovePropertyListenerBlock(device, &mute, .main, b)
        device = 0
        volumeBlock = nil
    }
}

// MARK: - Built-in display brightness (DisplayServices, the framework macOS itself uses)

enum Brightness {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Getter? = {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: Getter.self)
    }()
    private static let setter: Setter? = {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: Setter.self)
    }()

    /// The laptop's own screen, falling back to the main display
    static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(8, &ids, &count) == .success {
            if let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) { return builtIn }
        }
        return CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let g = getter else { return nil }
        var v: Float = 0
        return g(display, &v) == 0 ? v : nil
    }

    static func set(_ value: Float) {
        _ = setter?(display, min(1, max(0, value)))
    }
}

// MARK: - Optional: take over the volume and brightness keys, so macOS's own square doesn't appear
// This needs Accessibility permission. If the app quits or crashes, the keys go straight back to macOS.

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MediaKeyTap.shared.reenable()
        return Unmanaged.passUnretained(event)
    }
    // 14 is NX_SYSDEFINED; subtype 8 carries the media keys
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data = ns.data1
    let key = (data & 0xFFFF0000) >> 16
    let flags = data & 0xFFFF
    let isDown = ((flags & 0xFF00) >> 8) == 0x0A

    // 0 volume up, 1 volume down, 7 mute, 2 brightness up, 3 brightness down
    let volumeKey = key == 0 || key == 1 || key == 7
    let brightnessKey = key == 2 || key == 3
    if volumeKey && SystemVolume.volume() == nil { return Unmanaged.passUnretained(event) }
    if brightnessKey && Brightness.get() == nil { return Unmanaged.passUnretained(event) }
    guard volumeKey || brightnessKey else { return Unmanaged.passUnretained(event) }

    if isDown { MediaKeyTap.shared.handle(key: key, modifiers: ns.modifierFlags) }
    return nil      // swallowed: macOS won't show its own overlay
}

final class MediaKeyTap {
    static let shared = MediaKeyTap()

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { port != nil }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        guard Self.trusted else { return false }
        let mask = CGEventMask(1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: mediaKeyCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        port = tap
        source = src
        return true
    }

    func stop() {
        if let tap = port { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        port = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap = port { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(key: Int, modifiers: NSEvent.ModifierFlags) {
        // Option+Shift gives quarter steps, like macOS
        let fine = modifiers.contains(.option) && modifiers.contains(.shift)
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case 0: SystemVolume.step(step)
        case 1: SystemVolume.step(-step)
        case 7: SystemVolume.setMuted(!SystemVolume.isMuted())
        case 2, 3:
            guard let b = Brightness.get() else { return }
            let new = min(1, max(0, b + (key == 2 ? step : -step)))
            Brightness.set(new)
            Task { @MainActor in NotchController.shared.showBrightness(Double(new)) }
        default: break
        }
    }
}

// MARK: - Where the sound is going (for the AirPods icon in the island)

final class OutputRoute: ObservableObject {
    static let shared = OutputRoute()

    @Published private(set) var name = ""
    @Published private(set) var symbol = "laptopcomputer"
    @Published private(set) var isHeadphones = false
    @Published private(set) var deviceID: AudioDeviceID = 0

    /// The name without the owner, e.g. "AirPods Pro" rather than "Devony's AirPods Pro"
    var shortName: String {
        guard !name.isEmpty else { return "Speakers" }
        for mark in ["\u{2019}s ", "'s "] {
            if let r = name.range(of: mark) { return String(name[r.upperBound...]) }
        }
        return name
    }

    struct Output {
        let id: AudioDeviceID
        let name: String
    }

    /// Every device that can play sound (speakers, headphones, AirPlay, displays)
    static func outputs() -> [Output] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            // Only devices with output streams
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }
            let n = deviceName(id)
            return n.isEmpty ? nil : Output(id: id, name: n)
        }
    }

    /// Makes this device the Mac's sound output, like choosing it in Control Centre
    static func select(_ id: AudioDeviceID) {
        var addr = SystemVolume.defaultDeviceAddress
        var device = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr,
              let n = cfName else { return "" }
        return n.takeRetainedValue() as String
    }

    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        listener = changed
        var addr = SystemVolume.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, changed)
        refresh()
    }

    func refresh() {
        guard let d = SystemVolume.outputDevice() else { return }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let deviceName: String
        if AudioObjectGetPropertyData(d, &nameAddr, 0, nil, &size, &cfName) == noErr, let n = cfName {
            deviceName = n.takeRetainedValue() as String
        } else {
            deviceName = ""
        }

        var transportAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(d, &transportAddr, 0, nil, &size, &transport)

        let bluetooth = transport == UInt32(kAudioDeviceTransportTypeBluetooth)
            || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE)
        let sym: String
        if deviceName.contains("AirPods Pro") { sym = "airpodspro" }
        else if deviceName.contains("AirPods Max") { sym = "airpodsmax" }
        else if deviceName.contains("AirPods") { sym = "airpods" }
        else if bluetooth { sym = "headphones" }
        else if transport == UInt32(kAudioDeviceTransportTypeBuiltIn) { sym = "laptopcomputer" }
        else if transport == UInt32(kAudioDeviceTransportTypeAirPlay) { sym = "airplayaudio" }
        else if transport == UInt32(kAudioDeviceTransportTypeHDMI)
                    || transport == UInt32(kAudioDeviceTransportTypeDisplayPort) { sym = "tv" }
        else { sym = "hifispeaker" }

        name = deviceName
        symbol = sym
        isHeadphones = bluetooth || deviceName.contains("AirPods")
        self.deviceID = d
    }
}
