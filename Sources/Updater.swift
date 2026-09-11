import AppKit
import Security
import SwiftUI
import os

private let log = Logger(subsystem: "com.gelabs.oneo", category: "updater")

private struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
private struct Release: Decodable { let tag_name: String; let assets: [Asset]; struct Asset: Decodable { let name: String; let browser_download_url: URL } }

/// Pulls new builds from GitHub Releases. Nothing is installed unless the unpacked app carries a valid GE Labs
/// Developer ID signature; that check is the whole trust story, everything else here is plumbing.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var available: (version: String, url: URL)?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheck") } }
    /// Install verified updates as soon as they are found, then relaunch. Off by default.
    @Published var autoInstall: Bool { didSet { UserDefaults.standard.set(autoInstall, forKey: "autoInstall") } }

    nonisolated static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private static let latest = URL(string: "https://api.github.com/repos/weigibbor/one-o/releases/latest")!
    nonisolated private static let signer = "anchor apple generic and certificate leaf[subject.OU] = \"LE6BHLWBPY\""

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoCheck") as? Bool ?? true
        autoInstall = UserDefaults.standard.bool(forKey: "autoInstall")
        Task { try? await Task.sleep(for: .seconds(10)); check(manual: false) }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.check(manual: false) } }
    }

    /// Automatic checks fail silently (logged only); a manual check surfaces the error.
    func check(manual: Bool) {
        guard !checking, !installing, manual || autoCheck else { return }
        checking = true
        if manual { lastError = nil }
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: Self.latest)
                request.setValue("One-O", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw Failure(status == 404 ? "No releases published yet." : "GitHub answered \(status).") }
                guard let release = Self.parseRelease(data) else { throw Failure("The latest release has no One-O.zip.") }
                available = Self.isNewer(release.version, than: Self.currentVersion) ? release : nil
                lastChecked = .now
                if available != nil, autoInstall, !manual { install() }
            } catch {
                log.notice("check failed: \(error.localizedDescription, privacy: .public)")
                if manual { lastError = error.localizedDescription }
            }
        }
    }

    func install() {
        guard let update = available, !installing, !checking else { return }
        installing = true; lastError = nil
        let target = Bundle.main.bundleURL
        Task {
            do {
                let parked = try await Task.detached { try await Self.replace(target, with: update.url) }.value
                try Self.run("/usr/bin/open", "-n", target.path)
                try? FileManager.default.removeItem(at: parked)
                NSApp.terminate(nil)
            } catch {
                log.error("install failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription; installing = false
            }
        }
    }

    nonisolated static func parseRelease(_ data: Data) -> (version: String, url: URL)? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let zip = release.assets.first(where: { $0.name == "One-O.zip" }) else { return nil }
        return (String(release.tag_name.drop { $0 == "v" || $0 == "V" }), zip.browser_download_url)
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func numbers(_ version: String) -> [Int] {
        version.drop { $0 == "v" || $0 == "V" }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Download, unpack, verify, then swap the bundle at `target`. Returns where the previous bundle was parked.
    nonisolated private static func replace(_ target: URL, with url: URL) async throws -> URL {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard !target.path.contains("/AppTranslocation/") else { throw Failure("Move One-O to your Applications folder first, then update.") }
        guard fm.isWritableFile(atPath: parent.path) else { throw Failure("One-O can't replace itself in \(parent.path). Move it to your Applications folder.") }
        let work = fm.temporaryDirectory.appendingPathComponent("one-o-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var request = URLRequest(url: url)
        request.setValue("One-O", forHTTPHeaderField: "User-Agent")
        let (download, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download failed.") }
        let zip = work.appendingPathComponent("One-O.zip")
        try fm.moveItem(at: download, to: zip)
        try run("/usr/bin/ditto", "-x", "-k", zip.path, work.path)
        guard let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
        else { throw Failure("The download has no app inside.") }
        try verify(app)                                                     // the trust anchor: nothing unsigned by GE Labs gets past here
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path) // verified above; a quarantine flag would only block the relaunch
        let parked = fm.temporaryDirectory.appendingPathComponent("One-O-previous-\(UUID().uuidString).app")
        try relocate(target, to: parked)
        do { try relocate(app, to: target) } catch { try? relocate(parked, to: target); throw error }
        return parked
    }

    /// Static code check against the Developer ID requirement. Anything else, including an unsigned or ad-hoc build, is refused.
    nonisolated static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(signer as CFString, [], &requirement) == errSecSuccess, let requirement
        else { throw Failure("Could not read the update's signature.") }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode | kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "\(status)"
            throw Failure("Update rejected: not signed by GE Labs (\(reason)).")
        }
    }

    nonisolated private static func relocate(_ from: URL, to: URL) throws {
        do { try FileManager.default.moveItem(at: from, to: to) }
        catch { try run("/usr/bin/ditto", from.path, to.path); try FileManager.default.removeItem(at: from) }   // cross-volume: copy, then drop the source
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) exited with \(process.terminationStatus).") }
    }
}
