import CoreVideo
import MetalKit
import MetalPerformanceShaders
import simd

/// Matches FoldUniforms in Fold.metal (float2 + 5 floats, 8-byte aligned).
struct FoldUniforms {
    var res: SIMD2<Float>
    var phi: Float
    var motion: Float
    var eyeZ: Float
    var maxRadius: Float
    var maxLod: Float
}

/// Options for the effect, mirrored from UserDefaults by the controller.
struct EffectOptions {
    var hold = true            // hold-the-plane (default) vs the Duo-style absolute fold
    var warp = true            // hold: tilt-compensate the content, not just blur it
    var perspective = false    // hold: keystone taper from a finite eye position
    var blur = true            // hold: progressive blur
    var autoAnchor = true      // hold: settle back after the lid rests
    var anchorDelay = 0.15
}

/// Draws the latest desktop frame either as a "held plane" (delta from a settling reference angle) or as the
/// absolute Duo fold, easing per frame from the predicted lid angle.
final class FoldRenderer: NSObject, MTKViewDelegate {
    static let maxTilt: Float = 62 * .pi / 180     // Duo fold: panel rotation at a full fold

    var onFirstFrame: (() -> Void)?
    var onIdle: (() -> Void)?
    var onVisible: ((Bool) -> Void)?
    weak var view: MTKView?

    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let foldPipeline: MTLRenderPipelineState
    private let holdPipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var mipped: MTLTexture?
    private var blurLevels: [MTLTexture] = []
    private var blurFilters: [MPSImageGaussianBlur] = []
    private var blurDirty = true
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var pinned: Double?          // debug: fixed fold amount
    private var tracker = LidTracker()
    private var motion: FoldMotion
    private var anchor: HoldAnchor?
    private var delta: Float = 0
    var options = EffectOptions()
    private var settle = 0.09
    private var visible = false
    private var lastDraw: CFTimeInterval = 0
    private var frameDt: Double = 0
    private var announcedFirstFrame = false
    private let trace = UserDefaults.standard.bool(forKey: "trace")
    private var frames = 0; private var fpsWindowStart: CFTimeInterval = 0
    private var linkSum = 0.0, cpuSum = 0.0, gpuSum = 0.0, gpuCount = 0, waitSum = 0.0
    private var lastLogNs = 0.0

    init?(device: MTLDevice, openAngle: Double) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main) else { return nil }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let fold = pipeline("foldVertex", "foldFragment"), let hold = pipeline("holdVertex", "holdFragment") else { return nil }
        self.device = device; self.commands = queue; foldPipeline = fold; holdPipeline = hold
        motion = FoldMotion(openAngle: openAngle)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    func receive(_ buffer: CVPixelBuffer) { lock.lock(); latest = buffer; blurDirty = true; lock.unlock() }
    func setPinned(_ value: Double?) { lock.lock(); pinned = value; lock.unlock() }
    func setOpenAngle(_ value: Double) { lock.lock(); motion.openAngle = value; lock.unlock() }
    func setSettle(_ value: Double) { lock.lock(); settle = value; lock.unlock() }
    func setOptions(_ value: EffectOptions) { lock.lock(); options = value; lock.unlock() }
    func receiveLid(_ angle: Double, at now: CFTimeInterval) {
        lock.lock(); tracker.receive(angle, at: now); if anchor == nil { anchor = HoldAnchor(angle: angle, now: now) }; lock.unlock()
    }
    /// Take the current lid angle as the resting reference for the held plane.
    func anchorHere() { lock.lock(); if let a = tracker.angle { anchor?.anchor(at: a, now: CACurrentMediaTime()) }; lock.unlock() }
    var currentDelta: Float { lock.lock(); defer { lock.unlock() }; return delta }

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
        let now = CACurrentMediaTime()
        lock.lock()
        let buffer = latest
        let opts = options
        let estimate = tracker.estimate(at: now)
        var amount: Float = 0
        var nowVisible: Bool
        if opts.hold {
            // lid-plane behaviour, unchanged: raw sensor angle, 1.5° / 150 ms / 200 ms anchor, 80 ms filter, 1.25 rad clamp
            if var a = anchor, let raw = tracker.angle {
                a.delay = opts.anchorDelay
                a.update(angle: raw, now: now, enabled: opts.autoAnchor && pinned == nil)
                anchor = a
                let target = pinned.map { Float($0) * 0.6 } ?? Float((a.reference - raw) * .pi / 180)
                delta += (target - delta) * Float(1 - exp(-min(0.1, max(frameDt, 0)) / 0.08))
            }
            nowVisible = abs(delta) > 0.002 && (opts.blur || opts.warp)
        } else {
            let goal = pinned ?? motion.target(for: estimate)
            motion.advance(to: goal, dt: frameDt, settle: settle)
            amount = Float(motion.amount)
            nowVisible = motion.amount > 0.002
        }
        let visibilityChanged = nowVisible != visible; visible = nowVisible
        let wantBlur = blurDirty
        lock.unlock()
        if visibilityChanged { onVisible?(nowVisible) }
        if trace { FileHandle.standardError.write(Data(String(format: "T %.3f lid %.2f goal %.3f amount %.3f\n", now, estimate ?? -1, opts.hold ? Double(delta) : Double(amount), opts.hold ? Double(delta) : Double(amount)).utf8)) }

        frames += 1
        if fpsWindowStart == 0 { fpsWindowStart = now }
        else if now - fpsWindowStart >= 2 {
            let n = Double(frames); let fps = n / (now - fpsWindowStart)
            let line = String(format: "%.1f fps  link %.2f ms  cpu %.2f ms  drawableWait %.2f ms  gpu %.2f ms  %@ %.3f\n", fps, 1000 * linkSum / n, 1000 * cpuSum / n, 1000 * waitSum / n, gpuCount > 0 ? 1000 * gpuSum / Double(gpuCount) : 0, opts.hold ? "delta" : "fold", opts.hold ? delta : amount)
            FileHandle.standardError.write(Data(line.utf8))
            frames = 0; fpsWindowStart = now; linkSum = 0; cpuSum = 0; gpuSum = 0; gpuCount = 0; waitSum = 0
        }

        let tw = CACurrentMediaTime()
        let drawableMaybe = view.currentDrawable
        waitSum += CACurrentMediaTime() - tw
        guard let buffer, let pass = view.currentRenderPassDescriptor, let drawable = drawableMaybe,
              let cache, let commandBuffer = commands.makeCommandBuffer() else { return }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture) else { return }

        if opts.hold {
            if opts.blur, abs(delta) > 0.003, wantBlur { encodeBlur(commandBuffer, source: source); lock.lock(); blurDirty = false; lock.unlock() }
            let size = view.drawableSize
            var params = SIMD4<Float>(delta, Float(size.width / max(1, size.height)), opts.blur ? 1 : 0, opts.warp ? (opts.perspective ? 2 : 1) : 0)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.setRenderPipelineState(holdPipeline)
                encoder.setFragmentTexture(source, index: 0)
                for i in 0..<4 { encoder.setFragmentTexture(blurLevels.indices.contains(i) ? blurLevels[i] : source, index: i + 1) }
                encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        } else {
            guard let mips = mipTexture(width: width, height: height) else { return }
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
                encoder.setRenderPipelineState(foldPipeline)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
                encoder.setFragmentTexture(mips, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
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

    /// Four Gaussian levels (sigma 2, 6, 16, 40 per 1000 px of height) the shader blends between.
    private func encodeBlur(_ commandBuffer: MTLCommandBuffer, source: MTLTexture) {
        if blurLevels.first?.width != source.width || blurLevels.first?.height != source.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: source.width, height: source.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            blurLevels = (0..<4).compactMap { _ in device.makeTexture(descriptor: d) }
            blurFilters = [Float(2), 6, 16, 40].map { sigma in
                let f = MPSImageGaussianBlur(device: device, sigma: sigma * Float(source.height) / 1000)
                f.edgeMode = .clamp
                return f
            }
        }
        for (filter, destination) in zip(blurFilters, blurLevels) { filter.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination) }
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
