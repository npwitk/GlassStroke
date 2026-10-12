import CoreGraphics
import simd

/// A point on a stroke's centre line, with the pen's radius there.
public struct StrokePoint: Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var radius: Float

    public init(x: Float, y: Float, radius: Float) {
        self.x = x
        self.y = y
        self.radius = radius
    }
}

/// One pen stroke: its centre line from where the pen goes down to where it
/// lifts, in writing order. Coordinates are y-up, in any unit (the scene's
/// `unitsPerPoint` maps them to the image).
public struct Stroke: Hashable, Sendable {
    public var points: [StrokePoint]

    public init(points: [StrokePoint]) {
        self.points = points
    }

    /// A dot: a single pen tap.
    public static func dot(x: Float, y: Float, radius: Float) -> Stroke {
        Stroke(points: [StrokePoint(x: x, y: y, radius: radius)])
    }

    /// Length of the centre line.
    public var length: Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}

/// Strokes in writing order: what the pen draws, one stroke after another.
public struct Drawing: Sendable {
    public var strokes: [Stroke]

    public init(strokes: [Stroke]) {
        self.strokes = strokes
    }

    /// Bounds of the tubes (centre lines grown by their radius).
    public var bounds: CGRect {
        var x0 = Float.infinity, y0 = Float.infinity, x1 = -Float.infinity, y1 = -Float.infinity
        for s in strokes {
            for p in s.points {
                x0 = min(x0, p.x - p.radius); x1 = max(x1, p.x + p.radius)
                y0 = min(y0, p.y - p.radius); y1 = max(y1, p.y + p.radius)
            }
        }
        guard x0.isFinite else { return .zero }
        return CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
    }

    public var maxRadius: Float {
        strokes.flatMap(\.points).map(\.radius).max() ?? 0
    }
}
