import Foundation

/// `make check-updater`: the version comparison and release parsing, no network.
@main struct UpdaterCheck {
    static func main() {
        precondition(Updater.isNewer("v1.2.3", than: "1.2.2"), "patch bump")
        precondition(!Updater.isNewer("v1.2.3", than: "1.2.3"), "same version")
        precondition(Updater.isNewer("v1.10.0", than: "1.9.9"), "numeric, not lexical")
        precondition(!Updater.isNewer("v0.9.9", than: "1.0.0"), "older major")
        precondition(Updater.isNewer("v1.2", than: "1.1.5"), "short tag")
        precondition(!Updater.isNewer("garbage", than: "0.1.0"), "unparseable tag is never newer")

        let json = #"{"tag_name":"v1.2.3","assets":[{"name":"One-O.dmg","browser_download_url":"https://example.com/d"},{"name":"One-O.zip","browser_download_url":"https://example.com/One-O.zip"}]}"#
        let release = Updater.parseRelease(Data(json.utf8))
        precondition(release?.version == "1.2.3", "tag without v")
        precondition(release?.url.absoluteString == "https://example.com/One-O.zip", "zip asset picked")
        precondition(Updater.parseRelease(Data(#"{"tag_name":"v9.9.9","assets":[]}"#.utf8)) == nil, "no zip asset")
        precondition(Updater.parseRelease(Data("not json".utf8)) == nil, "bad json")
        print("check-updater: ok")
    }
}
