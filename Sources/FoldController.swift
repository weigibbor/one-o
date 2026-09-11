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
    private var replaying = false
    private var lastAngle: Double?
    private var lastMove: CFTimeInterval = 0
    private var opening = true
    private var rate = 60

    init() {
        let saved = UserDefaults.standard.double(forKey: "openAngle")
        openAngle = (25...180).contains(saved) ? saved : 100
        lid.onAngle = { [weak self] angle in Task { @MainActor in if self?.replaying != true { self?.receive(angle) } } }
        lid.start()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "debugAmount") != nil || defaults.bool(forKey: "trace") || defaults.bool(forKey: "replay") { Task { @MainActor in self.turnOn() } }
        // debug: `defaults write com.gelabs.oneo replay 1` plays a scripted slow close and re-open through the sensor path
        if defaults.bool(forKey: "replay") { replaying = true; startReplay() }
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
        if let last = lastAngle, angle != last { opening = angle > last; lastMove = now }
        lastAngle = angle
        guard angle >= 25 else { return }
        let restedFor = lastMove > 0 ? now - lastMove : 0
        // adopt a new rest angle only when it is close to the old one, or the lid has clearly settled there
        let adopt = opening && abs(angle - openAngle) > 0.5 && ((restedFor > 1.5 && abs(angle - openAngle) <= 10) || restedFor > 5)
        if angle > openAngle || adopt {
            openAngle = angle
            UserDefaults.standard.set(angle, forKey: "openAngle")
            renderer?.setOpenAngle(angle)
        }
    }

    private func startReplay() {
        // rest at 110 for 3 s, close 1°/300 ms to 60, hold 2 s, open 1°/120 ms back to 110, rest
        var script: [(Double, Double)] = [(0, 110)]
        var t = 3.0
        for a in stride(from: 109, through: 60, by: -1) { script.append((t, Double(a))); t += 0.3 }
        t += 2
        for a in stride(from: 61, through: 110, by: 1) { script.append((t, Double(a))); t += 0.12 }
        let start = CACurrentMediaTime()
        var index = 0; var current = 110.0
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            let now = CACurrentMediaTime() - start
            while index < script.count, script[index].0 <= now { current = script[index].1; index += 1 }
            Task { @MainActor in self?.receive(current) }
            if index >= script.count, now > t + 4 { timer.invalidate(); FileHandle.standardError.write(Data("REPLAY DONE\n".utf8)) }
        }
        RunLoop.main.add(timer, forMode: .common)
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
        let moved = lastMove > 0 && CACurrentMediaTime() - lastMove < 2
        // pre-warm on any lid motion so the mirror is already live when the fold begins
        if (moved || pinned != nil), !mirroring { beginMirror() }
        renderer?.setPinned(pinned)
        renderer?.receiveLid(angle, at: CACurrentMediaTime())
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
        panel.alphaValue = 0                 // shown only while there is a fold and a frame to show
        panel.orderFrontRegardless()
        self.overlay = panel; self.view = view; self.renderer = renderer
        var haveFrame = false, wantVisible = false
        let show = { [weak self] in self?.overlay?.alphaValue = (haveFrame && wantVisible) ? 1 : 0 }
        renderer.onFirstFrame = { Task { @MainActor in haveFrame = true; show() } }
        renderer.onVisible = { on in Task { @MainActor in wantVisible = on; show() } }
        renderer.onIdle = { [weak self] in Task { @MainActor in
            guard let self, self.lastMove > 0, CACurrentMediaTime() - self.lastMove > 2 else { return }   // keep warm while the lid still moves
            self.endMirror()
        } }

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
