import Foundation

public enum HandwritingError: Error, CustomStringConvertible {
    case noFont(String), noStrokes(String)
    public var description: String {
        switch self {
        case .noFont(let p): return "can't open the font at \(p) (Macintosh Skeletal ships with macOS 27)"
        case .noStrokes(let p): return "\(p) has no pen strokes; is it Apple's Macintosh Skeletal?"
        }
    }
}

/// Apple's "hello" handwriting, from the Macintosh Skeletal font on this device.
public enum HelloHandwriting {
    /// Where macOS 27 keeps the font.
    public static let systemFontPath =
        "/System/Library/PrivateFrameworks/SetupAssistantSupportUI.framework/Resources/MacintoshSkeletal.otf"

    /// `text` as pen strokes in writing order, in font units (1000 per em,
    /// y up, baseline at 0; lines 1.25 em apart). `weight` runs from 100
    /// (Thin) to 900 (Black); 500 is the hello screen's pen. Characters the
    /// font doesn't have are left out and returned in `missing`.
    public static func drawing(_ text: String, weight: Float = 500,
                               fontPath: String = systemFontPath) throws -> (drawing: Drawing, missing: String) {
        let font = try StrokeFont(path: fontPath)
        // the hello screen draws the pen 1.55x the stored radius; Thin to
        // Black run from 0.6x to 2.5x
        let thickness = 0.6 + (Double(min(max(weight, 100), 900)) - 100) / 800 * 1.9
        var missing = ""
        let marks = layout(text, font: font, thickness: thickness) { message in
            if let r = message.range(of: ": ") { missing = String(message[r.upperBound...]) }
        }
        let strokes = marks.map { m in
            Stroke(points: m.points.map { StrokePoint(x: Float($0.x), y: Float($0.y), radius: Float($0.r)) })
        }
        return (Drawing(strokes: strokes), missing)
    }

    /// The hello screen's write-on timing: pen progress (0...1) at time
    /// fraction `x` (0...1), measured from Apple's renderer; it starts a
    /// little fast and settles.
    public static func progress(at x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t + 0.2 * t * (1 - t)
    }

    /// The hello screen writes about 2.67 em of pen path per second.
    public static let penSpeed: Double = 2670     // font units per second
}
