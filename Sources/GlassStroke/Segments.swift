import simd

/// A short piece of a stroke: a cubic Hermite curve from `start` to `end`
/// (xyz, w = radius) with tangents, and the stretch of the whole drawing's
/// pen path it covers (0...1), which the write-on animation reveals.
public struct GlassSegment: Sendable {
    public var start: SIMD4<Float>
    public var end: SIMD4<Float>
    public var startTangent: SIMD4<Float>
    public var endTangent: SIMD4<Float>
    /// x, y: where the segment starts and ends along the pen path (0...1);
    /// z, w: 1 if it starts or ends its stroke (a round pen end there).
    public var range: SIMD4<Float>

    public init(start: SIMD4<Float>, end: SIMD4<Float>, startTangent: SIMD4<Float>, endTangent: SIMD4<Float>,
                range: SIMD2<Float>, startsStroke: Bool = false, endsStroke: Bool = false) {
        self.start = start
        self.end = end
        self.startTangent = startTangent
        self.endTangent = endTangent
        self.range = SIMD4(range.x, range.y, startsStroke ? 1 : 0, endsStroke ? 1 : 0)
    }
}

extension Drawing {
    /// Cuts every stroke into Hermite segments about `spacing` long (in the
    /// drawing's units; by default the typical pen radius), with Catmull-Rom
    /// tangents. Strokes should be given as dense centre-line samples.
    public func segments(spacing: Float? = nil) -> [GlassSegment] {
        let step = spacing ?? max(maxRadius, 1)
        // pen path length: strokes in order, a dot counts as its diameter
        let lengths = strokes.map { $0.points.count < 2 ? 2 * ($0.points.first?.radius ?? 0) : $0.length }
        let total = max(lengths.reduce(0, +), 1e-6)
        var out: [GlassSegment] = []
        var along: Float = 0
        for (stroke, length) in zip(strokes, lengths) {
            defer { along += length }
            guard let first = stroke.points.first else { continue }
            if stroke.points.count < 2 || length < 1e-6 {
                let p = SIMD4(first.x, first.y, 0, first.radius)
                out.append(GlassSegment(start: p, end: p, startTangent: .zero, endTangent: .zero,
                                        range: SIMD2(along / total, (along + length) / total), startsStroke: true, endsStroke: true))
                continue
            }
            let P = resample(stroke.points, step: step)
            let n = P.count
            var tangents: [SIMD3<Float>] = []
            for i in 0..<n {
                let a = P[max(i - 1, 0)], b = P[min(i + 1, n - 1)]
                let k: Float = (i == 0 || i == n - 1) ? 1 : 0.5
                tangents.append((SIMD3(b.x, b.y, 0) - SIMD3(a.x, a.y, 0)) * k)
            }
            var s: Float = 0
            for i in 0..<(n - 1) {
                let a = P[i], b = P[i + 1]
                let l = simd_length(SIMD2(b.x - a.x, b.y - a.y))
                out.append(GlassSegment(start: SIMD4(a.x, a.y, 0, a.w), end: SIMD4(b.x, b.y, 0, b.w),
                                        startTangent: SIMD4(tangents[i], 0), endTangent: SIMD4(tangents[i + 1], 0),
                                        range: SIMD2((along + s) / total, (along + s + l) / total),
                                        startsStroke: i == 0, endsStroke: i == n - 2))
                s += l
            }
        }
        return out
    }
}

/// Points every `step` along a polyline (x, y, -, radius in w), keeping both ends.
func resample(_ pts: [StrokePoint], step: Float) -> [SIMD4<Float>] {
    var cum: [Float] = [0]
    for (a, b) in zip(pts, pts.dropFirst()) { cum.append(cum.last! + hypot(b.x - a.x, b.y - a.y)) }
    let L = cum.last!
    let n = max(1, Int((L / step).rounded()))
    var out: [SIMD4<Float>] = []
    var j = 0
    for k in 0...n {
        let s = L * Float(k) / Float(n)
        while j < pts.count - 2 && cum[j + 1] < s { j += 1 }
        let seg = cum[j + 1] - cum[j]
        let u = seg > 0 ? min(max((s - cum[j]) / seg, 0), 1) : 0
        let a = pts[j], b = pts[j + 1]
        out.append(SIMD4(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, 0, a.radius + (b.radius - a.radius) * u))
    }
    return out
}
