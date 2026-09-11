import Foundation
import IOKit.hid

/// Live MacBook lid angle in degrees: 0 shut, 180 flat.
///
/// Apple exposes the lid position as a HID sensor (vendor 0x05AC, usage page 0x20, usage 0x8A).
/// It publishes no input reports, so the angle is pulled from feature report 1, bytes 1-2, little endian.
final class LidAngle {
    /// Latest angle, or nil once the sensor stops answering. Delivered on a private queue.
    var onAngle: ((Double?) -> Void)?

    private let queue = DispatchQueue(label: "com.gelabs.oneo.lid", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private var misses = 0
    private var hertz = 10.0

    private static let matching: [String: Any] = [
        kIOHIDVendorIDKey: 0x05AC, kIOHIDDeviceUsagePageKey: 0x0020, kIOHIDDeviceUsageKey: 0x008A,
    ]

    static func isPresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        defer { IOHIDManagerClose(manager, 0) }
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return !devices.isEmpty
    }

    func start() { queue.async { [weak self] in self?.attach() } }
    func stop() { queue.async { [weak self] in self?.detach() } }

    /// Poll rate: the display rate while folding, a trickle while idle.
    func setRate(_ hertz: Double) {
        queue.async { [weak self] in
            guard let self, self.hertz != hertz else { return }
            self.hertz = hertz
            if self.device != nil { self.schedule() }
        }
    }

    private func attach() {
        guard device == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, Self.matching as CFDictionary)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            IOHIDManagerClose(manager, 0); onAngle?(nil); return
        }
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }
            guard let angle = Self.read(candidate) else { IOHIDDeviceClose(candidate, 0); continue }
            self.manager = manager; self.device = candidate
            onAngle?(angle); schedule(); return
        }
        IOHIDManagerClose(manager, 0); onAngle?(nil)
    }

    private func detach() {
        timer?.cancel(); timer = nil
        if let device { IOHIDDeviceClose(device, 0) }
        if let manager { IOHIDManagerClose(manager, 0) }
        device = nil; manager = nil
    }

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let ns = Int(1_000_000_000 / max(hertz, 1))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(ns), leeway: .nanoseconds(ns / 16))
        timer.setEventHandler { [weak self] in self?.poll() }
        misses = 0; self.timer = timer; timer.resume()
    }

    private func poll() {
        guard let device else { return }
        if let angle = Self.read(device) { misses = 0; onAngle?(angle) }
        else { misses += 1; if misses == 12 { onAngle?(nil) } }
    }

    static func read(_ device: IOHIDDevice) -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3
        else { return nil }
        let degrees = Int(report[1]) | (Int(report[2]) << 8)
        return (0...180).contains(degrees) ? Double(degrees) : nil
    }
}
