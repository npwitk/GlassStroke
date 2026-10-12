import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// How the glass looks. Lengths are in the drawing's units.
public struct GlassStyle: Sendable {
    /// How far below the glass the refracted backdrop is (larger: stronger lensing).
    public var refractionDistance: Float = 2000
    /// Index of refraction at the tube's rim and where it faces the viewer.
    public var rimIndex: Float = 1.45
    public var faceIndex: Float = 1.1
    /// Spread between the red, green and blue indices (rainbow fringes).
    public var dispersion: Float = 0.02
    /// How flat the tube's top looks (higher: rounder).
    public var flatten: Float = 1.5
    /// Blur of the backdrop seen through the glass.
    public var backdropBlur: Float = 47.6
    /// Radius over which touching strokes melt together.
    public var blendRadius: Float = 10
    /// Milky light scattered inside the glass, and how fast it builds with thickness.
    public var milk: Float = 0.35
    public var milkDensity: Float = 0.006
    public var reflection: Float = 1
    public var specular: Float = 1
    /// Key light: elevation (z of its unit direction) and turns per second.
    public var lightElevation: Float = 0.3746
    public var lightSpeed: Float = 0.6571       // radians per second
    public var lightPhase: Float = -0.873       // radians at time 0
    public var lightIntensity: Float = 1
    /// Edge softness in pixels and supersampling per axis.
    public var edgeSoftness: Float = 1
    public var supersampling: Int = 2
    /// Development: output geometry instead of colour.
    public var debug: Float = 0

    public init() {}

    /// The key light's direction at `time` seconds.
    public func light(at time: Double) -> SIMD3<Float> {
        let a = lightPhase + lightSpeed * Float(time)
        let h = sqrt(max(0, 1 - lightElevation * lightElevation))
        return SIMD3(h * cos(a), h * sin(a), lightElevation)
    }
}

/// Where the drawing sits in the image: `unitsPerPixel` drawing units per
/// pixel, with the drawing point `origin` at the image's bottom-left corner.
public struct Placement: Sendable {
    public var unitsPerPixel: Float
    public var origin: SIMD2<Float>

    public init(unitsPerPixel: Float, origin: SIMD2<Float>) {
        self.unitsPerPixel = unitsPerPixel
        self.origin = origin
    }

    /// Centres `drawing` in a `width` x `height` image with `margin` (a
    /// fraction of the image) around it.
    public static func fit(_ drawing: Drawing, width: Int, height: Int, margin: Float = 0.1) -> Placement {
        let b = drawing.bounds
        let w = Float(width) * (1 - 2 * margin), h = Float(height) * (1 - 2 * margin)
        let upp = max(Float(b.width) / max(w, 1), Float(b.height) / max(h, 1), 1e-6)
        let cx = Float(b.midX), cy = Float(b.midY)
        return Placement(unitsPerPixel: upp, origin: SIMD2(cx - Float(width) / 2 * upp, cy - Float(height) / 2 * upp))
    }
}

public enum GlassError: Error, CustomStringConvertible {
    case noMetal, shader(String), texture(String)
    public var description: String {
        switch self {
        case .noMetal: return "Metal isn't available on this device"
        case .shader(let s): return "shader failed to compile: \(s)"
        case .texture(let s): return s
        }
    }
}

struct Uniforms {
    var frame: SIMD4<Float>
    var transform: SIMD4<Float>
    var light: SIMD4<Float>
    var write: SIMD4<Float>
    var glass: SIMD4<Float>
    var tone: SIMD4<Float>
    var tiles: SIMD4<Float>
    var iors: SIMD4<Float>
    var shape: SIMD4<Float>
    var shapeMap: SIMD4<Float>
}

/// Renders a drawing as glass tubes over a backdrop image.
public final class GlassRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var backdropKey: (ObjectIdentifier, Int, Int, Float)?
    private var sharp: MTLTexture?
    private var blurred: MTLTexture?

    public init(device: MTLDevice? = nil) throws {
        guard let d = device ?? MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw GlassError.noMetal }
        self.device = d
        queue = q
        do {
            let lib = try d.makeLibrary(source: shaderSource, options: nil)
            pipeline = try d.makeComputePipelineState(function: lib.makeFunction(name: "glassKernel")!)
        } catch {
            throw GlassError.shader("\(error)")
        }
    }

    /// One frame. `progress` is how much of the pen path is written (0...1);
    /// `time` drives the moving light. With `opaque`, the backdrop is drawn
    /// behind the glass; otherwise the glass alone, on transparency.
    public func render(segments: [GlassSegment], backdrop: CGImage, width: Int, height: Int,
                       placement: Placement, style: GlassStyle = GlassStyle(),
                       progress: Float = 1, time: Double = 0, opaque: Bool = true) throws -> CGImage {
        try render(segments: segments, shape: nil, backdrop: backdrop, width: width, height: height,
                   placement: placement, style: style, progress: progress, time: time, opaque: opaque)
    }

    /// A filled shape as inflated glass. If the shape has a draw-on order
    /// (`withDrawOrder()`), `progress` (0...1) writes it on like a pen.
    public func render(shape: GlassShape, backdrop: CGImage, width: Int, height: Int,
                       placement: Placement, style: GlassStyle = GlassStyle(),
                       progress: Float = 1, time: Double = 0, opaque: Bool = true) throws -> CGImage {
        try render(segments: [], shape: shape, backdrop: backdrop, width: width, height: height,
                   placement: placement, style: style, progress: progress, time: time, opaque: opaque)
    }

    private var shapeKey: ObjectIdentifier?
    private var shapeTexture: MTLTexture?
    private var shapeData: [Float] = []

    private func render(segments: [GlassSegment], shape: GlassShape?, backdrop: CGImage, width: Int, height: Int,
                        placement: Placement, style: GlassStyle,
                        progress: Float, time: Double, opaque: Bool) throws -> CGImage {
        try prepareBackdrop(backdrop, width: width, height: height, sigma: style.backdropBlur / placement.unitsPerPixel)
        let maxR = shape?.maxHeight ?? segments.map { max($0.start.w, $0.end.w) }.max() ?? 1
        // tiles of the image, each with the segments that can matter there
        // (refracted rays wander about a tube's width sideways)
        let tile = 16
        let tx = (width + tile - 1) / tile, ty = (height + tile - 1) / tile
        let margin = (2.5 * maxR + style.blendRadius) / placement.unitsPerPixel + 2
        var ranges = [UInt32](repeating: 0, count: tx * ty * 2)
        var buckets = [[UInt32]](repeating: [], count: tx * ty)
        for (i, s) in segments.enumerated() {
            // the curve stays inside its Bezier control hull
            let c1: SIMD4<Float> = s.start + s.startTangent / 3
            let c2: SIMD4<Float> = s.end - s.endTangent / 3
            let lo: SIMD4<Float> = simd_min(simd_min(s.start, s.end), simd_min(c1, c2))
            let hi: SIMD4<Float> = simd_max(simd_max(s.start, s.end), simd_max(c1, c2))
            let r: Float = max(s.start.w, s.end.w)
            let upp = placement.unitsPerPixel, o = placement.origin
            let x0: Float = (lo.x - r - o.x) / upp - margin
            let x1: Float = (hi.x + r - o.x) / upp + margin
            let y0: Float = (lo.y - r - o.y) / upp - margin
            let y1: Float = (hi.y + r - o.y) / upp + margin
            let a = max(0, Int(floor(x0)) / tile), b = min(tx - 1, Int(ceil(x1)) / tile)
            let c = max(0, Int(floor(y0)) / tile), d = min(ty - 1, Int(ceil(y1)) / tile)
            guard a <= b, c <= d else { continue }
            for y in c...d { for x in a...b { buckets[y * tx + x].append(UInt32(i)) } }
        }
        var items: [UInt32] = []
        for (k, b) in buckets.enumerated() {
            ranges[2 * k] = UInt32(items.count); ranges[2 * k + 1] = UInt32(b.count)
            items += b
        }
        if items.isEmpty { items = [0] }
        var segs = segments
        if segs.isEmpty { segs = [GlassSegment(start: .zero, end: .zero, startTangent: .zero, endTangent: .zero, range: SIMD2(2, 2))] }

        let L = style.light(at: time)
        var u = Uniforms(
            frame: SIMD4(Float(width), Float(height), placement.unitsPerPixel, Float(max(1, style.supersampling))),
            transform: SIMD4(placement.unitsPerPixel, placement.unitsPerPixel, placement.origin.x, placement.origin.y),
            light: SIMD4(L, style.lightIntensity),
            // tubes melt together over twice the radius while being written
            write: SIMD4(progress, style.blendRadius * (2 - min(max(progress, 0), 1)), -2.3 * maxR, Float(segments.count)),
            glass: SIMD4(style.refractionDistance, style.flatten, style.dispersion, style.edgeSoftness),
            tone: SIMD4(style.milk, style.milkDensity, style.reflection, style.specular),
            tiles: SIMD4(Float(tile), Float(tx), Float(ty), opaque ? 1 : 0),
            iors: SIMD4(style.rimIndex, style.faceIndex, style.debug, 0),
            shape: SIMD4(shape == nil ? 0 : 1, shape?.thickness ?? 1, shape?.unitsPerTexel ?? 1,
                         (shape?.order.isEmpty ?? true) ? 0 : progress * shape!.orderLength + 1e-3),
            shapeMap: SIMD4(shape?.origin.x ?? 0, shape?.origin.y ?? 0, Float(shape?.width ?? 1), Float(shape?.height ?? 1)))
        if shape != nil {
            // one tile holding nothing: the shape needs no segment lists
            ranges = [UInt32](repeating: 0, count: tx * ty * 2)
        }
        let sdfTexture = try shapeTexture(for: shape)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        guard let out = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { throw GlassError.noMetal }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(out, index: 0)
        enc.setTexture(blurred, index: 1)
        enc.setTexture(sharp, index: 2)
        enc.setTexture(sdfTexture, index: 3)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setBuffer(device.makeBuffer(bytes: segs, length: MemoryLayout<GlassSegment>.stride * segs.count), offset: 0, index: 1)
        enc.setBuffer(device.makeBuffer(bytes: ranges, length: 4 * ranges.count), offset: 0, index: 2)
        enc.setBuffer(device.makeBuffer(bytes: items, length: 4 * items.count), offset: 0, index: 3)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw GlassError.texture("render failed: \(e)") }
        return image(of: out)
    }

    /// The backdrop scaled to fill the image (cropping the overflow), and a
    /// blurred copy of it.
    private func prepareBackdrop(_ img: CGImage, width: Int, height: Int, sigma: Float) throws {
        let key = (ObjectIdentifier(img), width, height, sigma)
        if let k = backdropKey, k.0 == key.0, k.1 == key.1, k.2 == key.2, k.3 == key.3 { return }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GlassError.texture("can't draw the backdrop") }
        let s = max(CGFloat(width) / CGFloat(img.width), CGFloat(height) / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false)
        sd.usage = [.shaderRead]
        guard let st = device.makeTexture(descriptor: sd) else { throw GlassError.noMetal }
        st.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: width * 4)
        // blur in linear light, transparent beyond the edges
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        bd.usage = [.shaderRead, .shaderWrite]
        guard let lin = device.makeTexture(descriptor: bd), let bt = device.makeTexture(descriptor: bd),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw GlassError.noMetal }
        blit.endEncoding()
        let copy = MPSImageConversion(device: device, srcAlpha: .premultiplied, destAlpha: .premultiplied, backgroundColor: nil, conversionInfo: nil)
        copy.encode(commandBuffer: cb, sourceTexture: st, destinationTexture: lin)
        if sigma > 0.25 {
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.edgeMode = .zero
            blur.encode(commandBuffer: cb, sourceTexture: lin, destinationTexture: bt)
        } else {
            let c2 = MPSImageConversion(device: device, srcAlpha: .premultiplied, destAlpha: .premultiplied, backgroundColor: nil, conversionInfo: nil)
            c2.encode(commandBuffer: cb, sourceTexture: lin, destinationTexture: bt)
        }
        cb.commit()
        cb.waitUntilCompleted()
        sharp = st
        blurred = bt
        backdropKey = key
    }

    private func shapeTexture(for shape: GlassShape?) throws -> MTLTexture {
        let w = shape?.width ?? 1, h = shape?.height ?? 1
        if let t = shapeTexture, let s = shape, t.width == w, t.height == h, shapeData == s.distances + s.heights + s.order + s.orderSpeed { return t }
        if shape == nil, let t = shapeTexture, t.width == 1 { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { throw GlassError.noMetal }
        // texture rows run top-down; the field's rows bottom-up
        // texel: (signed distance to the outline, glass height, draw-on order, pen speed)
        var rows = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { rows[4 * i] = 1e6 }
        if let s = shape { for y in 0..<h { for x in 0..<w {
            let o = 4 * ((h - 1 - y) * w + x), i = y * w + x
            rows[o] = s.distances[i]; rows[o + 1] = s.heights[i]; rows[o + 2] = s.order.isEmpty ? 0 : s.order[i]; rows[o + 3] = s.orderSpeed.isEmpty ? 1 : s.orderSpeed[i]
        } } }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rows, bytesPerRow: w * 16)
        shapeTexture = t
        shapeData = shape.map { $0.distances + $0.heights + $0.order + $0.orderSpeed } ?? []
        return t
    }

    private func image(of t: MTLTexture) -> CGImage {
        let w = t.width, h = t.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        t.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
