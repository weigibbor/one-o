import AppKit
import SwiftUI

@main
struct OneOApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    @StateObject private var fold = FoldController()

    var body: some Scene {
        Window("One-O", id: "settings") {
            SettingsView(fold: fold).onAppear { delegate.onQuit = { fold.shutDown() } }
        }
        .windowStyle(.hiddenTitleBar).windowResizability(.contentSize).defaultPosition(.center)
        MenuBarExtra("One-O", systemImage: fold.isOn ? "laptopcomputer.and.arrow.down" : "laptopcomputer") {
            Button(fold.isOn ? "Turn off" : "Turn on") { fold.isOn ? fold.turnOff() : fold.turnOn() }.disabled(fold.isStarting)
            Divider()
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
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
            if let message = fold.message { Text(message).font(.callout).foregroundStyle(.orange) }
            if fold.needsPermission {
                Button("Open Screen Recording settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Text("Frames never leave this Mac. Built by GE Labs.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20).frame(width: 400)
    }
}
