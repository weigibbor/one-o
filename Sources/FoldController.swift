import AppKit
import MetalKit
import ScreenCaptureKit
import SwiftUI

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
    private var mirroring = false
    private var rate = 60

    init() {
        let saved = UserDefaults.standard.double(forKey: "openAngle")
        openAngle = (25...180).contains(saved) ? saved : 100
        lid.onAngle = { [weak self] angle in Task { @MainActor in self?.receive(angle) } }
        lid.start()
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

    /// Remember the current lid angle as the resting open position.
    func setOpenPosition() {
        guard let lidAngle, lidAngle >= 25 else { message = "Open the lid to your usual position first."; return }
        openAngle = lidAngle
        UserDefaults.standard.set(lidAngle, forKey: "openAngle")
        renderer?.setOpenAngle(lidAngle)
        message = nil
    }

    func shutDown() { endMirror(); lid.stop() }

    private func receive(_ angle: Double?) {
        let wasReady = sensorReady
        sensorReady = angle != nil; lidAngle = angle
        if wasReady, angle == nil, isOn { turnOff(); message = "The lid sensor stopped answering. Turn One-O on again to reconnect." }
        guard isOn, let angle else { return }
        let target = FoldMotion(openAngle: openAngle).target(for: angle)
        if target > 0, !mirroring { beginMirror() }
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
        view.preferredFramesPerSecond = rate
        view.delegate = renderer
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        panel.alphaValue = 0                 // stays invisible until the first mirrored frame lands
        panel.orderFrontRegardless()
        self.overlay = panel; self.view = view; self.renderer = renderer
        renderer.onFirstFrame = { [weak self] in Task { @MainActor in self?.overlay?.alphaValue = 1 } }
        renderer.onIdle = { [weak self] in Task { @MainActor in self?.endMirror() } }

        let capture = DesktopCapture()
        capture.onFrame = { [weak renderer] buffer in renderer?.receive(buffer) }
        capture.onStop = { [weak self] _ in Task { @MainActor in self?.endMirror() } }
        self.capture = capture
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        let windowID = CGWindowID(panel.windowNumber)
        Task {
            do { try await capture.start(displayID: displayID, excluding: [windowID], pixelSize: pixelSize, fps: rate) }
            catch { needsPermission = true; message = "Screen Recording is off for One-O. Allow it, then turn One-O on again."; endMirror() }
        }
    }

    private func endMirror() {
        guard mirroring else { return }
        mirroring = false
        capture?.stop(); capture = nil
        view?.isPaused = true; view?.delegate = nil
        overlay?.orderOut(nil); overlay = nil; view = nil; renderer = nil
    }
}
