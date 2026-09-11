import CoreVideo
import MetalKit
import simd
import os

private let log = Logger(subsystem: "com.gelabs.oneo", category: "render")

/// Matches FoldUniforms in Fold.metal (float2 + 5 floats, 8-byte aligned).
struct FoldUniforms {
    var res: SIMD2<Float>
    var phi: Float
    var motion: Float
    var eyeZ: Float
    var maxRadius: Float
    var maxLod: Float
}

/// Draws the latest desktop frame through the fold projection, easing the fold amount every frame.
final class FoldRenderer: NSObject, MTKViewDelegate {
    static let maxTilt: Float = 62 * .pi / 180     // panel rotation at a full fold

    var onFirstFrame: (() -> Void)?
    var onIdle: (() -> Void)?

    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var mipped: MTLTexture?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var target = 0.0
    private var motion: FoldMotion
    private var lastDraw: CFTimeInterval = 0
    private var announcedFirstFrame = false
    private var frameDt: Double = 0
    private var frames = 0; private var fpsWindowStart: CFTimeInterval = 0
    private var linkSum = 0.0, cpuSum = 0.0, gpuSum = 0.0, gpuCount = 0
    weak var view: MTKView?

    init?(device: MTLDevice, openAngle: Double) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device; self.commands = queue; self.pipeline = pipeline
        motion = FoldMotion(openAngle: openAngle)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    func receive(_ buffer: CVPixelBuffer) { lock.lock(); latest = buffer; lock.unlock() }
    func setTarget(_ value: Double) { lock.lock(); target = value; lock.unlock() }
    func setOpenAngle(_ value: Double) { lock.lock(); motion.openAngle = value; lock.unlock() }
    func targetAmount(for lidAngle: Double?) -> Double { lock.lock(); defer { lock.unlock() }; return motion.target(for: lidAngle) }
    func reset() { lock.lock(); motion.reset(); target = 0; latest = nil; announcedFirstFrame = false; lastDraw = 0; lock.unlock() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Driven by a CADisplayLink so ProMotion panels actually run us at their top rate.
    @objc func tick(_ link: CADisplayLink) {
        frameDt = lastDraw == 0 ? 0 : link.targetTimestamp - lastDraw
        lastDraw = link.targetTimestamp
        linkSum += link.targetTimestamp - link.timestamp
        let t0 = CACurrentMediaTime()
        view?.draw()
        cpuSum += CACurrentMediaTime() - t0
    }

    func draw(in view: MTKView) {
        lock.lock()
        let buffer = latest; let goal = target
        motion.advance(to: goal, dt: frameDt)
        let amount = Float(motion.amount); let idle = motion.isIdle && goal == 0
        lock.unlock()
        let now = CACurrentMediaTime()
        frames += 1
        if fpsWindowStart == 0 { fpsWindowStart = now }
        else if now - fpsWindowStart >= 2 { let n = Double(self.frames); let fps = n / (now - self.fpsWindowStart)
            let line = String(format: "%.1f fps  link %.2f ms  cpu %.2f ms  gpu %.2f ms  fold %.2f\n", fps, 1000 * linkSum / n, 1000 * cpuSum / n, gpuCount > 0 ? 1000 * gpuSum / Double(gpuCount) : 0, amount)
            log.notice("\(line, privacy: .public)"); FileHandle.standardError.write(Data(line.utf8))
            linkSum = 0; cpuSum = 0; gpuSum = 0; gpuCount = 0; frames = 0; fpsWindowStart = now }
        if idle { onIdle?() }

        guard let buffer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cache, let commandBuffer = commands.makeCommandBuffer() else { return }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture), let mips = mipTexture(width: width, height: height) else { return }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: mips, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.generateMipmaps(for: mips)
            blit.endEncoding()
        }
        let size = view.drawableSize
        var uniforms = FoldUniforms(res: SIMD2(Float(size.width), Float(size.height)), phi: amount * Self.maxTilt, motion: amount,
                                    eyeZ: 2.6 * Float(size.height), maxRadius: 0.045 * Float(size.height), maxLod: Float(mips.mipmapLevelCount - 1))
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
            encoder.setFragmentTexture(mips, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        commandBuffer.addCompletedHandler { [weak self] cb in
            _ = cvTexture                                            // keep the CV texture alive until the GPU is done
            guard let self else { return }
            self.lock.lock(); self.gpuSum += cb.gpuEndTime - cb.gpuStartTime; self.gpuCount += 1; self.lock.unlock()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if !announcedFirstFrame { announcedFirstFrame = true; onFirstFrame?() }
    }

    private func mipTexture(width: Int, height: Int) -> MTLTexture? {
        if let mipped, mipped.width == width, mipped.height == height { return mipped }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        mipped = device.makeTexture(descriptor: descriptor)
        return mipped
    }
}
