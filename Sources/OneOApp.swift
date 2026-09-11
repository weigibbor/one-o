import AppKit
import SwiftUI

@main
struct OneOApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    @StateObject private var fold = FoldController()
    @StateObject private var updater = Updater()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("One-O", id: "settings") {
            SettingsView(fold: fold, updater: updater).onAppear { delegate.onQuit = { fold.shutDown() } }
        }
        .windowStyle(.hiddenTitleBar).windowResizability(.contentSize).defaultPosition(.center)
        MenuBarExtra("One-O", systemImage: fold.isOn ? "laptopcomputer.and.arrow.down" : "laptopcomputer") {
            Button(fold.isOn ? "Turn off" : "Turn on") { fold.isOn ? fold.turnOff() : fold.turnOn() }.disabled(fold.isStarting)
            Divider()
            Button(updater.available.map { "Update to \($0.version)…" } ?? "Check for Updates…") {
                if updater.available != nil { updater.install() }
                else { updater.check(manual: true); openWindow(id: "settings"); NSApp.activate() }   // the result shows in the Settings status line
            }.disabled(updater.checking || updater.installing)
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
            Button("Anchor Here") { fold.anchorHere() }.disabled(!fold.isOn || !fold.options.hold)
            Divider()
            Button("Quit One-O") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}

struct SettingsView: View {
    @ObservedObject var fold: FoldController
    @ObservedObject var updater: Updater

    private var updateStatus: String {
        if updater.installing { return "Installing…" }
        if updater.checking { return "Checking…" }
        if let update = updater.available { return "\(update.version) available" }
        return updater.lastChecked.map { "Up to date, checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 30, weight: .light))
                VStack(alignment: .leading) {
                    Text("One-O").font(.title2.weight(.semibold))
                    Text("Your desktop folds with the lid.").foregroundStyle(.secondary).font(.callout)
                }
            }
            Divider()
            Toggle("Fold the desktop when the lid closes", isOn: Binding(get: { fold.isOn }, set: { $0 ? fold.turnOn() : fold.turnOff() }))
                .disabled(fold.isStarting)
            HStack {
                Text(fold.lidAngle.map { "Lid \(Int($0))°" } ?? "Lid sensor not found").monospacedDigit()
                Spacer()
                Text("Rests at \(Int(fold.openAngle))°, learned automatically").foregroundStyle(.secondary).monospacedDigit()
            }.font(.callout)
            Divider()
            Picker("Effect", selection: Binding(get: { fold.options.hold }, set: { fold.options.hold = $0 })) {
                Text("Hold the plane").tag(true); Text("Duo fold").tag(false)
            }.pickerStyle(.segmented)
            if fold.options.hold {
                Toggle("Hold content angle", isOn: Binding(get: { fold.options.warp }, set: { fold.options.warp = $0 }))
                Toggle("Perspective taper", isOn: Binding(get: { fold.options.perspective }, set: { fold.options.perspective = $0 })).disabled(!fold.options.warp)
                Toggle("Progressive blur", isOn: Binding(get: { fold.options.blur }, set: { fold.options.blur = $0 }))
                Toggle("Settle back when still", isOn: Binding(get: { fold.options.autoAnchor }, set: { fold.options.autoAnchor = $0 }))
                Picker("Pause before settling", selection: Binding(get: { fold.options.anchorDelay }, set: { fold.options.anchorDelay = $0 })) {
                    ForEach([0.15, 0.3, 0.5, 1.0, 2.0], id: \.self) { Text($0 < 1 ? "\(Int($0 * 1000)) ms" : "\(Int($0)) s").tag($0) }
                }.disabled(!fold.options.autoAnchor)
            }
            if let message = fold.message { Text(message).font(.callout).foregroundStyle(.orange) }
            if fold.needsPermission {
                Button("Open Screen Recording settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Divider()
            Toggle("Check for updates automatically", isOn: $updater.autoCheck)
            HStack {
                Text("Version \(Updater.currentVersion)")
                Spacer()
                Text(updateStatus).foregroundStyle(.secondary)
            }.font(.callout)
            if let error = updater.lastError { Text(error).font(.callout).foregroundStyle(.orange) }
            if let update = updater.available { Button("Update to \(update.version)…") { updater.install() }.disabled(updater.installing) }
            Text("Frames never leave this Mac. Built by GE Labs.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20).frame(width: 420)
    }
}
