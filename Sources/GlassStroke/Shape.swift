import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A filled shape (an icon, a symbol, a logo) to render as puffed glass.
///
/// The shape is inflated like a balloon: its height comes from a smooth
/// membrane over the outline (a Poisson solution), square-rooted so that any
/// stroke-like part has a round cross-section, just like a pen tube, and
/// wide parts become smooth domes. There are no ridges or creases, because
/// the membrane is smooth everywhere inside the shape.
public struct GlassShape: Sendable {
    /// Signed distance to the outline in scene units (negative inside), per texel.
    public let distances: [Float]
    /// Height of the glass's top surface above its middle plane, per texel.
    public let heights: [Float]
    public let width: Int
    public let height: Int
    /// Scene units of texel (0, 0)'s corner (bottom-left) and units per texel.
    public let origin: SIMD2<Float>
    public let unitsPerTexel: Float
    /// Scales the glass's thickness (1: round tubes, like the handwriting).
    public var thickness: Float = 1
    /// Draw-on order: for each texel, when the pen reaches it (in scene
    /// units of pen travel for `withDrawOrder`, in seconds for
    /// `symbolDrawOn`). Empty if not computed.
    public private(set) var order: [Float] = []
    /// How far the pen moves per unit of `order` there (to shape its tip).
    public private(set) var orderSpeed: [Float] = []
    /// `order` when the whole shape is drawn.
    public private(set) var orderLength: Float = 0

    mutating func setOrder(_ order: [Float], speed: [Float], length: Float) {
        self.order = order
        orderSpeed = speed
        orderLength = length
    }

    public var bounds: CGRect {
        CGRect(x: CGFloat(origin.x), y: CGFloat(origin.y),
               width: CGFloat(Float(width) * unitsPerTexel), height: CGFloat(Float(height) * unitsPerTexel))
    }

    /// The thickest point's height.
    public var maxHeight: Float { (heights.max() ?? 0) * thickness }

    /// From a mask image (its alpha; covered = inside) placed over `bounds`
    /// in scene units (y up). The mask should leave some empty margin.
    public init(mask: CGImage, bounds: CGRect) {
        let w = mask.width, h = mask.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        let upt = Float(bounds.width) / Float(w)
        // rows from the bottom up
        var inside = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { inside[y * w + x] = px[(h - 1 - y) * w + x] >= 128 } }
        self.init(inside: inside, width: w, height: h, origin: SIMD2(Float(bounds.minX), Float(bounds.minY)), unitsPerTexel: upt)
    }

    /// From a mask given as texels (rows bottom-up).
    init(inside: [Bool], width w: Int, height h: Int, origin: SIMD2<Float>, unitsPerTexel upt: Float) {
        let dOut = edt(inside, w, h, target: true)      // distance to the nearest inside texel
        let dIn = edt(inside, w, h, target: false)      // ... to the nearest outside texel
        var d = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            d[i] = (inside[i] ? -(dIn[i] - 0.5) : (dOut[i] - 0.5)) * upt
        }
        d = blur(d, w, h, sigma: 1)                     // smooth out the texel steps

        // The membrane: lap(u) = -1 inside, u = 0 on the outline. A strip of
        // half-width a gets u = (a^2 - x^2) / 2, so sqrt(2u) is a half circle.
        let u = poisson(inside, w, h, spacing: upt)
        // Near the outline, u ~ q * depth with q smooth: take the depth from
        // the exact distance field there, so the edge has no texel steps.
        var q = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where inside[i] { q[i] = u[i] / max(-d[i], 0.5 * upt) }
        q = blurInside(q, inside, w, h, sigma: 2)
        var z = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let depth = max(-d[i], 0)
            guard depth > 0 else { continue }
            let nearEdge = sqrt(2 * q[i] * depth), deep = sqrt(2 * max(u[i], 0))
            let k = min(max((depth / upt - 2) / 4, 0), 1)
            z[i] = nearEdge + (deep - nearEdge) * k * k * (3 - 2 * k)
        }
        distances = d
        heights = z
        width = w
        height = h
        self.origin = origin
        unitsPerTexel = upt
    }

    /// What the pen has drawn after `progress` (0...1) of the draw-on, as a
    /// shape of its own: inflated afresh, so each stroke ends in a round
    /// glass tip and crossings only swell once both strokes are there.
    /// Without a draw order, the whole shape.
    public func revealed(at progress: Float) -> GlassShape {
        guard !order.isEmpty else { return self }
        if progress >= 1 { var s = self; s.order = []; s.orderSpeed = []; return s }
        // a few texels of pen travel of slack: a stroke's edge texels reach
        // half coverage a little after its middle, which would fray the edge
        let speed = orderSpeed.first ?? 1
        let limit = progress * orderLength + 4 * unitsPerTexel / max(speed, 1e-6)
        let inside = zip(distances, order).map { $0 < 0 && $1 <= limit }
        var s = GlassShape(inside: inside, width: width, height: height, origin: origin, unitsPerTexel: unitsPerTexel)
        s.thickness = thickness
        return s
    }

    /// From a path in scene units (y up), rasterised at `resolution` texels
    /// across its longer side.
    public init(path: CGPath, resolution: Int = 1024) {
        let b = path.boundingBoxOfPath
        let pad = max(b.width, b.height) * 0.08
        let box = b.insetBy(dx: -pad, dy: -pad)
        let scale = CGFloat(resolution) / max(box.width, box.height)
        let w = max(Int((box.width * scale).rounded(.up)), 1), h = max(Int((box.height * scale).rounded(.up)), 1)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.addPath(path)
        ctx.fillPath()
        self.init(mask: ctx.makeImage()!, bounds: CGRect(x: box.minX, y: box.minY, width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }

    #if canImport(AppKit)
    /// An SF Symbol, `size` scene units tall, rasterised at `resolution`
    /// texels across.
    public static func symbol(_ name: String, size: CGFloat = 1000, weight: NSFont.Weight = .regular,
                              resolution: Int = 1024) -> GlassShape? {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(resolution) * 0.7, weight: weight)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let pad = CGFloat(resolution) * 0.08
        let w = Int((img.size.width + 2 * pad).rounded(.up)), h = Int((img.size.height + 2 * pad).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: pad, y: pad, width: img.size.width, height: img.size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let mask = ctx.makeImage() else { return nil }
        let k = size / img.size.height
        return GlassShape(mask: mask, bounds: CGRect(x: -pad * k, y: -pad * k, width: CGFloat(w) * k, height: CGFloat(h) * k))
    }
    #endif
}

extension GlassShape {
    /// The same shape with a draw-on order, so it can be written on like
    /// the hello handwriting: each separate piece is drawn in turn (top to
    /// bottom, then left to right), starting from one of its ends, by
    /// distance travelled inside the shape.
    public func withDrawOrder() -> GlassShape {
        var s = self
        let w = width, h = height, n = w * h
        let inside = distances.map { $0 < 0 }
        var comp = [Int](repeating: -1, count: n)
        var pieces: [[Int]] = []
        for i in 0..<n where inside[i] && comp[i] < 0 {
            var stack = [i], members: [Int] = []
            comp[i] = pieces.count
            while let j = stack.popLast() {
                members.append(j)
                let x = j % w, y = j / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let k = ny * w + nx
                    if inside[k] && comp[k] < 0 { comp[k] = pieces.count; stack.append(k) }
                }
            }
            pieces.append(members)
        }
        // pieces top to bottom (in bands a twentieth of the height), then
        // left to right
        let band = max(h / 20, 1)
        func key(_ p: [Int]) -> (Int, Int) {
            let top = p.map { $0 / w }.max()!, left = p.map { $0 % w }.min()!
            return (-(top / band), left)
        }
        let sorted = pieces.sorted { key($0) < key($1) }
        var order = [Float](repeating: 0, count: n)
        var offset: Float = 0
        for piece in sorted {
            // the pen starts at the piece's leftmost point (the highest, if
            // several), as handwriting does
            let start = piece.min { ($0 % w, -($0 / w)) < ($1 % w, -($1 / w)) }!
            let g = geodesic(from: [start], inside, w, h)
            let len = piece.map { g[$0] }.max()!
            for i in piece { order[i] = (offset + g[i]) * unitsPerTexel }
            offset += len
        }
        // outside: the order of the nearest inside texel, so the reveal
        // edge stays put under bilinear filtering
        for i in 0..<n where !inside[i] { order[i] = offset * unitsPerTexel + 1e5 }
        s.setOrder(order, speed: [Float](repeating: 1, count: n), length: offset * unitsPerTexel)
        return s
    }
}

/// Shortest path length (texels) inside the mask from the seeds, moving to
/// any of 8 neighbours (Dijkstra).
func geodesic(from seeds: [Int], _ inside: [Bool], _ w: Int, _ h: Int) -> [Float] {
    var dist = [Float](repeating: .infinity, count: w * h)
    var heap: [(Float, Int)] = []
    func push(_ e: (Float, Int)) {
        heap.append(e); var i = heap.count - 1
        while i > 0 { let p = (i - 1) / 2; if heap[p].0 <= heap[i].0 { break }; heap.swapAt(p, i); i = p }
    }
    func pop() -> (Float, Int) {
        let top = heap[0]; let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last; var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1; var m = i
                if l < heap.count && heap[l].0 < heap[m].0 { m = l }
                if r < heap.count && heap[r].0 < heap[m].0 { m = r }
                if m == i { break }
                heap.swapAt(i, m); i = m
            }
        }
        return top
    }
    for s in seeds { dist[s] = 0; push((0, s)) }
    let steps: [(Int, Int, Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
                                      (1, 1, 1.4142), (-1, 1, 1.4142), (1, -1, 1.4142), (-1, -1, 1.4142)]
    while !heap.isEmpty {
        let (d, i) = pop()
        if d > dist[i] { continue }
        let x = i % w, y = i / w
        for (dx, dy, c) in steps {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
            let k = ny * w + nx
            guard inside[k] else { continue }
            let nd = d + c
            if nd < dist[k] { dist[k] = nd; push((nd, k)) }
        }
    }
    return dist
}

/// Solves lap(u) = -1 inside the mask with u = 0 outside (grid spacing in
/// scene units), coarse to fine with successive over-relaxation.
func poisson(_ inside: [Bool], _ w: Int, _ h: Int, spacing: Float) -> [Float] {
    // pyramid of masks, halving until small
    var masks = [(inside, w, h)]
    while masks.last!.1 > 48 && masks.last!.2 > 48 {
        let (m, mw, mh) = masks.last!
        let nw = (mw + 1) / 2, nh = (mh + 1) / 2
        var n = [Bool](repeating: false, count: nw * nh)
        for y in 0..<nh { for x in 0..<nw {
            var c = 0
            for dy in 0..<2 { for dx in 0..<2 {
                let sx = min(2 * x + dx, mw - 1), sy = min(2 * y + dy, mh - 1)
                if m[sy * mw + sx] { c += 1 }
            } }
            n[y * nw + x] = c >= 2
        } }
        masks.append((n, nw, nh))
    }
    var u: [Float] = []
    for level in stride(from: masks.count - 1, through: 0, by: -1) {
        let (m, mw, mh) = masks[level]
        let s = spacing * Float(1 << level), s2 = s * s
        // start from the coarser solution
        var v = [Float](repeating: 0, count: mw * mh)
        if !u.isEmpty {
            let (_, cw, ch) = masks[level + 1]
            for y in 0..<mh { for x in 0..<mw where m[y * mw + x] {
                v[y * mw + x] = u[min(y / 2, ch - 1) * cw + min(x / 2, cw - 1)]
            } }
        }
        let iterations = level == masks.count - 1 ? 600 : 80
        for _ in 0..<iterations {
            for y in 0..<mh { for x in 0..<mw {
                let i = y * mw + x
                guard m[i] else { continue }
                let l = x > 0 ? v[i - 1] : 0, r = x < mw - 1 ? v[i + 1] : 0
                let b = y > 0 ? v[i - mw] : 0, t = y < mh - 1 ? v[i + mw] : 0
                let g = (l + r + b + t + s2) * 0.25
                v[i] += 1.9 * (g - v[i])
            } }
        }
        u = v
    }
    return u
}

/// Gaussian blur over the inside of a mask only (outside texels neither
/// contribute nor change).
func blurInside(_ f: [Float], _ inside: [Bool], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
    let wgt = inside.map { $0 ? Float(1) : 0 }
    let num = blur(zip(f, wgt).map { $0 * $1 }, w, h, sigma: sigma)
    let den = blur(wgt, w, h, sigma: sigma)
    var out = f
    for i in 0..<(w * h) where inside[i] { out[i] = num[i] / max(den[i], 1e-6) }
    return out
}

/// Separable Gaussian blur of a field.
func blur(_ f: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
    let r = Int((sigma * 3).rounded(.up))
    let k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
    let ks = k.reduce(0, +)
    var tmp = f, out = f
    for y in 0..<h { for x in 0..<w {
        var acc: Float = 0
        for i in -r...r { acc += k[i + r] * f[y * w + min(max(x + i, 0), w - 1)] }
        tmp[y * w + x] = acc / ks
    } }
    for y in 0..<h { for x in 0..<w {
        var acc: Float = 0
        for i in -r...r { acc += k[i + r] * tmp[min(max(y + i, 0), h - 1) * w + x] }
        out[y * w + x] = acc / ks
    } }
    return out
}

/// Euclidean distance (in texels) from each texel to the nearest texel whose
/// `inside` equals `target` (Felzenszwalb & Huttenlocher).
func edt(_ inside: [Bool], _ w: Int, _ h: Int, target: Bool) -> [Float] {
    let inf: Float = 1e20
    var f = inside.map { $0 == target ? 0 : inf }
    var col = [Float](repeating: 0, count: max(w, h)), out = col
    func pass(_ n: Int) {
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0; z[0] = -inf; z[1] = inf
        if n > 1 {
            for q in 1..<n {
                var s: Float
                repeat {
                    let p = v[k]
                    s = ((col[q] + Float(q * q)) - (col[p] + Float(p * p))) / Float(2 * q - 2 * p)
                    if s <= z[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1
                v[k] = q; z[k] = s; z[k + 1] = inf
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            out[q] = Float((q - p) * (q - p)) + col[p]
        }
    }
    for x in 0..<w {
        for y in 0..<h { col[y] = f[y * w + x] }
        pass(h)
        for y in 0..<h { f[y * w + x] = out[y] }
    }
    for y in 0..<h {
        for x in 0..<w { col[x] = f[y * w + x] }
        pass(w)
        for x in 0..<w { f[y * w + x] = out[x] }
    }
    return f.map { $0 >= inf / 2 ? 1e6 : sqrt($0) }
}
