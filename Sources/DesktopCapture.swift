import CoreMedia
import ScreenCaptureKit

/// Live frames of one display, excluding our own overlay so the mirror does not recurse.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.gelabs.oneo.capture", qos: .userInteractive)

    enum Failure: Error { case noDisplay }

    func start(displayID: CGDirectDisplayID, excluding windowIDs: Set<CGWindowID>, pixelSize: CGSize, fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
        else { throw Failure.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { windowIDs.contains($0.windowID) })
        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width); config.height = Int(pixelSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = false                // the real cursor stays on top; two cursors would show otherwise
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        onFrame?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
