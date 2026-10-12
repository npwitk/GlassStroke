#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

extension GlassShape {
    /// An SF Symbol (or a custom symbol in your app's assets) with Apple's
    /// own Draw On animation: SwiftUI's `.symbolEffect(.drawOn)` is played
    /// once in an off-screen window and recorded, and the moment each point
    /// is drawn becomes the shape's draw-on order. Rendering with `progress`
    /// then writes the glass on exactly as SF Symbols draws the symbol, using
    /// the draw paths its designer set up.
    ///
    /// Must run on the main thread of an app (or a command-line tool that
    /// sets up `NSApplication`). `size` is the symbol's height in scene units.
    @MainActor @available(macOS 26.0, *)
    public static func symbolDrawOn(_ name: String, size: CGFloat = 1000, resolution: Int = 900,
                                    weight: Font.Weight = .regular, bundle: Bundle? = nil) -> GlassShape? {
        let recorder = DrawOnRecorder(name: name, resolution: resolution, weight: weight, bundle: bundle)
        guard let frames = recorder.record(), let last = frames.last else { return nil }
        let w = resolution, h = resolution
        // The shape: everything drawn at any moment. (The finished symbol
        // cuts a thin gap around a stroke that crosses over another; in
        // glass, the tubes simply meet.)
        var ink = last.alpha
        for f in frames { for i in 0..<ink.count where f.alpha[i] > ink[i] { ink[i] = f.alpha[i] } }
        guard let mask = maskImage(ink, w, h) else { return nil }
        // scale: the symbol's ink height becomes `size`
        var top = 0, bottom = h
        for y in 0..<h where ink[y * w ..< (y + 1) * w].contains(where: { $0 >= 128 }) { top = max(top, y); bottom = min(bottom, y) }
        guard top > bottom else { return nil }
        let k = size / CGFloat(top - bottom + 1)
        var shape = GlassShape(mask: mask, bounds: CGRect(x: 0, y: -CGFloat(bottom) * k, width: CGFloat(w) * k, height: CGFloat(h) * k))

        // When each texel was first drawn (half covered), between frames.
        // Rows of the recorded frames run bottom-up already.
        let n = w * h
        var arrival = [Float](repeating: .infinity, count: n)
        for i in 0..<n {
            var prevA: Float = 0, prevT = frames[0].time
            for f in frames {
                let a = Float(f.alpha[i]) / 255
                if a >= 0.5 {
                    let u = a > prevA ? (0.5 - prevA) / (a - prevA) : 1
                    arrival[i] = Float(prevT) + max(0, min(1, u)) * Float(f.time - prevT)
                    break
                }
                prevA = a; prevT = f.time
            }
        }
        let end = arrival.filter { $0.isFinite }.max() ?? 1
        let inside = shape.distances.map { $0 < 0 }
        var order = [Float](repeating: end + 1e3, count: n)
        for i in 0..<n where inside[i] { order[i] = arrival[i] }
        // Edge texels that never reached half coverage in a frame take the
        // time of their nearest drawn neighbour (else they'd appear last).
        var pending = (0..<n).filter { inside[$0] && !order[$0].isFinite }
        while !pending.isEmpty {
            var next: [Int] = []
            var updates: [(Int, Float)] = []
            for i in pending {
                let x = i % w, y = i / w
                var best = Float.infinity
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    best = min(best, order[ny * w + nx])
                }
                if best.isFinite && best < end + 1 { updates.append((i, best)) } else { next.append(i) }
            }
            if updates.isEmpty { for i in next { order[i] = end }; break }
            for (i, t) in updates { order[i] = t }
            pending = next
        }
        // soften the steps between recorded frames
        order = blurInside(order, inside, w, h, sigma: 1.5)
        // Pen speed: how far the front moves per second, used to shape the
        // glass tip (time behind the tip -> distance). One typical speed for
        // the symbol: local estimates break down where strokes cross (the
        // arrival time jumps there) and would dent the glass.
        let upt = shape.unitsPerTexel
        let reach = 4
        var samples: [Float] = []
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) where inside[y * w + x] {
            let i = y * w + x
            var g: Float = 0
            for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                let nx = x + dx * reach, ny = y + dy * reach
                guard nx >= 0, ny >= 0, nx < w, ny < h, inside[ny * w + nx] else { continue }
                let len = Float(reach) * (dx != 0 && dy != 0 ? 1.4142 : 1) * upt
                let v = abs(order[ny * w + nx] - order[i]) / len      // seconds per unit
                g = max(g, v)
            }
            // along a stroke the slope is the steepest direction; the median
            // over the symbol ignores crossings, where it jumps
            if g > 1e-7 { samples.append(1 / g) }
        } }
        samples.sort()
        let typical = samples.isEmpty ? 1000 : samples[samples.count / 2]
        let speed = [Float](repeating: typical, count: n)
        shape.setOrder(order, speed: speed, length: end)
        return shape
    }

    static func maskImage(_ alpha: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        // alpha rows bottom-up -> an RGBA image (rows top-down), black ink
        var rows = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { rows[((h - 1 - y) * w + x) * 4 + 3] = alpha[y * w + x] } }
        guard let provider = CGDataProvider(data: Data(rows) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

@MainActor
private final class DrawOnModel: ObservableObject {
    @Published var on = false
}

@MainActor @available(macOS 26.0, *)
private struct DrawOnView: View {
    @ObservedObject var model: DrawOnModel
    let name: String
    let size: CGFloat
    let weight: Font.Weight
    let bundle: Bundle?

    var body: some View {
        ZStack {
            Color.clear
            image.font(.system(size: size, weight: weight)).foregroundStyle(.black)
                .symbolEffect(.drawOn, isActive: !model.on)
        }
    }

    var image: Image { bundle.map { Image(name, bundle: $0) } ?? Image(systemName: name) }
}

@MainActor @available(macOS 26.0, *)
private final class DrawOnRecorder {
    struct Frame { var time: Double; var alpha: [UInt8] }
    let name: String, resolution: Int, weight: Font.Weight, bundle: Bundle?

    init(name: String, resolution: Int, weight: Font.Weight, bundle: Bundle?) {
        self.name = name; self.resolution = resolution; self.weight = weight; self.bundle = bundle
    }

    func record() -> [Frame]? {
        _ = NSApplication.shared
        let model = DrawOnModel()
        let r = CGFloat(resolution)
        let host = NSHostingView(rootView: DrawOnView(model: model, name: name, size: r * 0.55, weight: weight, bundle: bundle)
            .frame(width: r, height: r))
        host.frame = NSRect(x: 0, y: 0, width: r, height: r)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: r, height: r),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        var frames: [Frame] = []
        withAnimation { model.on = true }
        let start = Date()
        var lastCover = -1, still = 0
        while Date().timeIntervalSince(start) < 6 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            guard let a = snapshot(host) else { return nil }
            frames.append(Frame(time: Date().timeIntervalSince(start), alpha: a))
            // stop once nothing has changed for a while
            let cover = a.reduce(0) { $0 + Int($1 >= 128 ? 1 : 0) }
            if cover == lastCover && cover > 0 { still += 1 } else { still = 0 }
            lastCover = cover
            if still > 30 { break }
        }
        return frames.isEmpty ? nil : frames
    }

    /// The view's current on-screen state (mid-animation), as alpha, rows bottom-up.
    private func snapshot(_ view: NSView) -> [UInt8]? {
        guard let layer = view.layer else { return nil }
        let w = resolution, h = resolution
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(w) / view.bounds.width, y: CGFloat(h) / view.bounds.height)
        (layer.presentation() ?? layer).render(in: ctx)
        return px
    }
}
#endif
