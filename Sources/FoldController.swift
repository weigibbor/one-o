import AppKit
import MetalKit
import ScreenCaptureKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.gelabs.oneo", category: "fold")

/// Owns the sensor, the capture, the overlay window, and the renderer. Everything UI-facing lives here.
@MainActor
final class FoldController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var isStarting = false
    @Published private(set) var sensorReady = false
    @Published private(set) var lidAngle: Double?
    @Published private(set) var openAngle: Double
    @Published private(set) var message: String?
    @Published private(set) var needsPermission = false

    private let lid = LidAngle()
    private var capture: DesktopCapture?
    private var renderer: FoldRenderer?
    private var overlay: NSPanel?
    private var view: MTKView?
    private var link: CADisplayLink?
    private var mirroring = false
    private var lastAngle: Double?
    private var lastMove: CFTimeInterval = 0
    private var opening = true
    private var rate = 60

    init() {
        let saved = UserDefaults.standard.double(forKey: "openAngle")
        openAngle = (25...180).contains(saved) ? saved : 100
        lid.onAngle = { [weak self] angle in Task { @MainActor in self?.receive(angle) } }
        lid.start()
        if UserDefaults.standard.object(forKey: "debugAmount") != nil { Task { @MainActor in self.turnOn() } }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.endMirror() } }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lid.stop(); self?.lid.start() } }
    }

    func turnOn() {
        guard !isOn, !isStarting else { return }
        isStarting = true; message = nil
        Task {
            // Touch ScreenCaptureKit once so the permission prompt happens now, not mid-fold.
            do { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true); needsPermission = false }
            catch { needsPermission = true; message = "One-O needs Screen Recording to mirror the desktop."; isStarting = false; return }
            isOn = true; isStarting = false
            lid.setRate(Double(refreshRate()))
        }
    }

    func turnOff() { endMirror(); isOn = false; lid.setRate(10) }

    /// The open position follows the lid on its own: wherever it rests after opening becomes the baseline.
    /// A pause while closing keeps the old baseline so the fold does not snap flat halfway; opening past the
    /// baseline adopts the new angle at once.
    private func learnOpenPosition(_ angle: Double, now: CFTimeInterval) {
        if let last = lastAngle, angle != last {
            opening = angle > last
            // whole-degree steps: ease over twice the gap between steps so slow closes glide instead of pulsing
            if lastMove > 0 { renderer?.setSettle(min(max(2 * (now - lastMove), 0.1), 0.6)) }
            lastMove = now
        }
        lastAngle = angle
        guard angle >= 25 else { return }
        let rested = lastMove > 0 && now - lastMove > 1.5
        if angle > openAngle || (rested && opening && abs(angle - openAngle) > 0.5) {
            openAngle = angle
            UserDefaults.standard.set(angle, forKey: "openAngle")
            renderer?.setOpenAngle(angle)
        }
    }

    func shutDown() { endMirror(); lid.stop() }

    private func receive(_ angle: Double?) {
        let wasReady = sensorReady
        sensorReady = angle != nil; lidAngle = angle
        if wasReady, angle == nil, isOn { turnOff(); message = "The lid sensor stopped answering. Turn One-O on again to reconnect." }
        if let angle { learnOpenPosition(angle, now: CACurrentMediaTime()) }
        guard isOn, let angle else { return }
        // debug: `defaults write com.gelabs.oneo debugAmount 0.5` pins the fold; delete the key to go live
        let pinned = UserDefaults.standard.object(forKey: "debugAmount") as? Double
        let target = pinned ?? FoldMotion(openAngle: openAngle).target(for: angle)
        if target > 0, !mirroring { log.notice("lid \(angle, format: .fixed(precision: 0))° target \(target, format: .fixed(precision: 2)) → begin mirror"); beginMirror() }
        renderer?.setTarget(target)
    }

    private func refreshRate() -> Int { max(NSScreen.main?.maximumFramesPerSecond ?? 60, 60) }

    private func beginMirror() {
        guard !mirroring, let screen = NSScreen.main, let device = MTLCreateSystemDefaultDevice(),
              let renderer = FoldRenderer(device: device, openAngle: openAngle) else { return }
        mirroring = true
        rate = refreshRate()
        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true                  // we drive draws from the display link below
        view.enableSetNeedsDisplay = false
        view.delegate = renderer
        renderer.view = view
        let link = view.displayLink(target: renderer, selector: #selector(FoldRenderer.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link.add(to: .main, forMode: .common)
        self.link = link
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        panel.alphaValue = 0                 // stays invisible until the first mirrored frame lands
        panel.orderFrontRegardless()
        self.overlay = panel; self.view = view; self.renderer = renderer
        renderer.onFirstFrame = { [weak self] in Task { @MainActor in log.notice("first frame, overlay visible"); self?.overlay?.alphaValue = 1 } }
        renderer.onIdle = { [weak self] in Task { @MainActor in self?.endMirror() } }

        let capture = DesktopCapture()
        capture.onFrame = { [weak renderer] buffer in renderer?.receive(buffer) }
        capture.onStop = { [weak self] _ in Task { @MainActor in self?.endMirror() } }
        self.capture = capture
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        let windowID = CGWindowID(panel.windowNumber)
        Task {
            do { try await capture.start(displayID: displayID, excluding: [windowID], pixelSize: pixelSize, fps: 60) }
            catch {
                log.error("capture failed: \(error.localizedDescription, privacy: .public)")
                endMirror(); isOn = false; lid.setRate(10)
                needsPermission = true; message = "Screen Recording is off for One-O. Allow it, quit and reopen One-O, then turn it on."
            }
        }
    }

    private func endMirror() {
        guard mirroring else { return }
        mirroring = false
        log.notice("end mirror")
        capture?.stop(); capture = nil
        link?.invalidate(); link = nil
        view?.delegate = nil
        overlay?.orderOut(nil); overlay = nil; view = nil; renderer = nil
    }
}
