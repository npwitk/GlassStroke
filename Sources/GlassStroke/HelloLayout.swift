// Text in Apple's "hello" handwriting, as pen strokes in writing order.
//
// The strokes are read from Macintosh Skeletal, the font macOS 27 ships for
// its hello screen, on the device this runs on; nothing of Apple's is bundled.
// Same layout as hello-write in the Macintosh-Skeletal-Filled repository:
// Core Text picks each letter's form, the font's private `strk` table gives
// its strokes (uniform cubic B-splines with in-letter snapping and
// injection), and letters join by merging the exit and lead-in strokes with
// three predicted points.

import CoreGraphics
import CoreText
import Foundation

// MARK: - Apple's stroke data

/// A control point in font units (1000 per em) with its pen radius.
struct P {
    var x, y, r: Double
    static func + (a: P, b: P) -> P { P(x: a.x + b.x, y: a.y + b.y, r: a.r + b.r) }
    static func - (a: P, b: P) -> P { P(x: a.x - b.x, y: a.y - b.y, r: a.r - b.r) }
    static func * (a: P, k: Double) -> P { P(x: a.x * k, y: a.y * k, r: a.r * k) }
}

enum Kind { case open, closed, dot, other }

struct StrokeDef {
    var kind: Kind
    var points: [P]
    var deferred: Bool
    var start: [String: Any]
    var end: [String: Any]
}

struct GlyphDef {
    var strokes: [StrokeDef]
    var forward: Int?
    var backward: Int?
}

final class StrokeFont {
    let ctFont: CTFont
    let postscriptName: String
    private let cgFont: CGFont
    private var raw: [String: [String: Any]] = [:]
    private var cache: [String: GlyphDef] = [:]

    init(path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], let d = descs.first else {
            throw HandwritingError.noFont(path)
        }
        ctFont = CTFontCreateWithFontDescriptor(d, 1000, nil)
        cgFont = CTFontCopyGraphicsFont(ctFont, nil)
        postscriptName = CTFontCopyPostScriptName(ctFont) as String
        guard let data = CTFontCopyTable(ctFont, CTFontTableTag(0x7374_726B), []) as Data?,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let glyphs = json["glyphs"] as? [String: [String: Any]] else {
            throw HandwritingError.noStrokes(path)
        }
        raw = glyphs
    }

    func name(_ g: CGGlyph) -> String? { cgFont.name(for: g) as String? }

    func glyph(_ name: String) -> GlyphDef? {
        if let g = cache[name] { return g }
        guard let r = raw[name] else { return nil }
        let info = r["info"] as? [String: Any] ?? [:]
        var strokes: [StrokeDef] = []
        for s in r["strokes"] as? [[String: Any]] ?? [] {
            let type = s["type"] as? String ?? ""
            let kind: Kind = type == "Open" ? .open : type == "Closed" ? .closed : type == "Dot" ? .dot : .other
            let pts = (s["points"] as? [[Double]] ?? []).map { P(x: $0[0] * 1000, y: $0[1] * 1000, r: ($0.count > 3 ? $0[3] : 0.034) * 1000) }
            let si = s["info"] as? [String: Any] ?? [:]
            strokes.append(StrokeDef(kind: kind, points: pts, deferred: (si["deferred"] as? String ?? "Not") != "Not",
                                     start: si["start"] as? [String: Any] ?? [:], end: si["end"] as? [String: Any] ?? [:]))
        }
        strokes = Self.snapped(strokes)
        // An injector end gets the midpoint of its last two points, as Apple does,
        // so it runs straight into the curve it flows into.
        for i in strokes.indices where strokes[i].kind == .open && (strokes[i].end["injector"] as? Bool ?? false) && strokes[i].points.count >= 2 {
            let n = strokes[i].points.count
            strokes[i].points.insert((strokes[i].points[n - 2] + strokes[i].points[n - 1]) * 0.5, at: n - 1)
        }
        let tokens = Set(name.split(separator: ".").map(String.init))
        func index(_ key: String, _ allowed: Bool) -> Int? {
            guard allowed, let i = info[key] as? Int, strokes.indices.contains(i), strokes[i].kind == .open else { return nil }
            return i
        }
        let g = GlyphDef(strokes: strokes,
                         forward: index("joinsForward", tokens.isDisjoint(with: ["final", "isolated"])),
                         backward: index("joinsBackward", tokens.isDisjoint(with: ["initial", "isolated"])))
        cache[name] = g
        return g
    }

    /// Apple's in-glyph snapping: a stroke end with a snapping target moves to
    /// the nearest point on the target's curve (the shift fading over the last
    /// few points) and, by its tangency, turns to run along it.
    static func snapped(_ src: [StrokeDef]) -> [StrokeDef] {
        let falloff = [1.0, 1.0, 0.78, 0.52, 0.22]
        var out = src
        for (i, s) in src.enumerated() {
            var pts = s.points
            for side in ["start", "end"] {
                let inf = side == "start" ? s.start : s.end
                guard let t = inf["snappingTarget"] as? Int, src.indices.contains(t), src[t].kind == .open, pts.count >= 2 else { continue }
                let target = spline(src[t].points, lo: -1, hi: src[t].points.count - 3, n: 12)
                let idx = side == "start" ? Array(pts.indices) : Array(pts.indices.reversed())
                let e = pts[idx[0]]
                let (q, tdir) = nearest(on: target, to: e)
                let dx = q.x - e.x, dy = q.y - e.y
                for (w, k) in zip(falloff, idx) {
                    pts[k].x += w * dx
                    pts[k].y += w * dy
                }
                let tw = inf["tangency"] as? Double ?? 0
                if tw > 0 {
                    let p0 = pts[idx[0]], p1 = pts[idx[1]]
                    let own = atan2(p1.y - p0.y, p1.x - p0.x)
                    let goal = [tdir, tdir + .pi, tdir - .pi].min { abs(remainder($0 - own, 2 * .pi)) < abs(remainder($1 - own, 2 * .pi)) }!
                    let ang = own + tw * remainder(goal - own, 2 * .pi)
                    let L = hypot(p1.x - p0.x, p1.y - p0.y)
                    pts[idx[1]].x = p0.x + L * cos(ang)
                    pts[idx[1]].y = p0.y + L * sin(ang)
                }
            }
            out[i].points = pts
        }
        return out
    }
}

func nearest(on poly: [P], to p: P) -> (P, Double) {
    var best = (Double.infinity, poly.first ?? p, 0.0)
    for (a, b) in zip(poly, poly.dropFirst()) {
        let ax = b.x - a.x, ay = b.y - a.y
        let L = ax * ax + ay * ay
        let u = L == 0 ? 0 : max(0, min(1, ((p.x - a.x) * ax + (p.y - a.y) * ay) / L))
        let q = P(x: a.x + u * ax, y: a.y + u * ay, r: a.r)
        let d = hypot(q.x - p.x, q.y - p.y)
        if d < best.0 { best = (d, q, atan2(ay, ax)) }
    }
    return (best.1, best.2)
}

/// Samples of the uniform cubic B-spline over windows lo...hi of control
/// points F (window j uses F[j...j+3]; index -1 and F.count are the
/// reflected end points), as Apple's CursiveTextPath draws strokes.
func spline(_ F: [P], lo: Int, hi: Int, n: Int) -> [P] {
    let m = F.count
    if m == 0 { return [] }
    if m < 3 {
        guard lo <= -1, m == 2 else { return lo <= -1 ? F : [] }
        return (0...n).map { F[0] + (F[1] - F[0]) * (Double($0) / Double(n)) }
    }
    let Q = [F[0] * 2 - F[1]] + F + [F[m - 1] * 2 - F[m - 2]]
    var out: [P] = []
    for j in max(lo, -1)...min(hi, m - 3) {
        let p0 = Q[j + 1], p1 = Q[j + 2], p2 = Q[j + 3], p3 = Q[j + 4]
        for k in (out.isEmpty ? 0 : 1)...n {
            let t = Double(k) / Double(n)
            let b0 = (1 - t) * (1 - t) * (1 - t) / 6
            let b1 = (3 * t * t * t - 6 * t * t + 4) / 6
            let b2 = (-3 * t * t * t + 3 * t * t + 3 * t + 1) / 6
            let b3 = t * t * t / 6
            out.append(p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3)
        }
    }
    return out
}

// MARK: - Joins

// Apple joins two letters by merging the first one's exit stroke and the
// next one's lead-in into one spline: the exit keeps its points up to A[-4],
// the lead-in resumes at B[3], and three new points replace the six between.
// Apple computes those three at run time; this linear model was fitted to
// 32,000 joins measured from Apple's renderer (median error about 3 units of
// 1000 per em). Inputs, in the second letter's coordinates: x of A[-4...-1]
// and B[0...3], then their y, then 1.
let joinXY: [[[Double]]] = [
    [[0.4949726, 0.1723505, 0.1377389, -0.0304804, 0.0653109, -0.0159149, 0.1318472, 0.0459609, -0.1268478, 0.0255661, 0.0877418, -0.0482173, -0.0064429, -0.1100533, 0.208943, -0.0276127, 3.5438218], [0.0574221, -0.0735342, 0.0260998, -0.0058011, 0.0034063, -0.0265181, 0.0753975, -0.0371179, 0.0198814, 0.646028, 0.2445557, -0.0809914, 0.0837955, 0.0663123, 0.000333, 0.0157922, -0.4371404]],
    [[-0.0089053, 0.3892389, 0.1191794, 0.0301353, 0.0734633, 0.1135645, 0.2060395, 0.0701389, 0.0024322, 0.0824628, -0.1578921, 0.0171661, 0.0451258, -0.306201, 0.3290762, -0.0217219, 2.3137324], [-0.0022318, 0.1332116, -0.0579926, -0.0495222, 0.009037, -0.1569918, 0.1382457, -0.004409, -0.0279292, 0.1105469, 0.4163747, -0.0069152, -0.0013597, 0.3206744, 0.2269159, -0.0319338, 0.9799182]],
    [[-0.0314099, 0.2710952, -0.1089662, 0.074532, 0.0255183, 0.0775666, 0.3477397, 0.3376523, 0.0258789, 0.0251875, -0.066639, -0.0110183, 0.0883286, -0.1303232, -0.1728316, 0.2135459, 8.9073254], [-0.0017809, 0.0999596, 0.0804942, -0.0864021, -0.0228813, -0.0063275, -0.2165197, 0.151661, -0.0253678, 0.0832267, 0.0875, 0.020736, -0.0589939, 0.1243926, 0.5031169, 0.2753641, -0.1108724]],
]
// Radii of the three points: from the radii of A[-4...-1] and B[0...3].
let joinR: [[Double]] = [[0.0128719, 0.7949741, 0.0401987, 0.1046851, 0.1046851, -0.2840064, 0.3390868, -0.1124787], [-0.0529535, -0.0026889, 0.572522, 0.0538296, 0.0538296, 0.0454989, 0.4414529, -0.1114802], [0.0051961, -0.0069754, 0.0146387, -0.0360253, -0.0360253, 0.5164981, 0.2947575, 0.2479438]]

func joinPoints(exit A: [P], entry B: [P]) -> [P] {
    var A = A, B = B
    if A.count == 3 { A.insert(A[0] * 2 - A[1], at: 0) }
    if B.count == 3 { B.append(B[2] * 2 - B[1]) }
    let X = Array(A.suffix(4)) + Array(B.prefix(4))
    let f = X.map(\.x) + X.map(\.y) + [1]
    return (0..<3).map { k in
        P(x: zip(joinXY[k][0], f).reduce(0) { $0 + $1.0 * $1.1 },
          y: zip(joinXY[k][1], f).reduce(0) { $0 + $1.0 * $1.1 },
          r: zip(joinR[k], X.map(\.r)).reduce(0) { $0 + $1.0 * $1.1 })
    }
}

// MARK: - Layout: text -> pen strokes in writing order

/// One thing the pen draws: a stroke (dense centreline with radius) or a dot.
struct Mark {
    var points: [P]          // font units, y up
    var isDot: Bool
    var length: Double
}

/// The curve a stroke's end flows into (Apple's "injector"), in world units.
struct Injection {
    var curve: [P]
    var closed: Bool          // a loop (the bowl of o, a, ...)
    var target: Int           // its world stroke
    var follow: P?            // where the glyph's next stroke on it starts (the tail of o)
}

final class WorldStroke {
    var kind: Kind
    var points: [P]
    var deferred: Bool
    var injection: Injection?
    var alive = true
    var root: Int
    init(kind: Kind, points: [P], deferred: Bool, root: Int) {
        self.kind = kind; self.points = points; self.deferred = deferred; self.root = root
    }
}

func layout(_ text: String, font: StrokeFont, thickness: Double, warn: (String) -> Void) -> [Mark] {
    var world: [WorldStroke] = []
    func find(_ i: Int) -> Int { var i = i; while world[i].root != i { i = world[i].root }; return i }

    struct Inst { var name: String; var def: GlyphDef; var refs: [Int]; var mark: Bool }
    // A run of glyphs that may join; nil = a break (space, line end, missing letter).
    var seq: [Inst?] = []
    var missing = Set<Character>()
    let lineHeight = 1250.0
    let lines = text.decomposedStringWithCanonicalMapping.components(separatedBy: "\n")
    for (li, line) in lines.enumerated() {
        let attr = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font.ctFont] as CFDictionary)!
        let ct = CTLineCreateWithAttributedString(attr)
        let oy = -Double(li) * lineHeight
        for run in CTLineGetGlyphRuns(ct) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let rf = attrs[kCTFontAttributeName] as! CTFont
            let n = CTRunGetGlyphCount(run)
            let range = CTRunGetStringRange(run)
            if CTFontCopyPostScriptName(rf) as String != font.postscriptName {
                let s = (line as NSString).substring(with: NSRange(location: range.location, length: range.length))
                for c in s where !c.isWhitespace { missing.insert(c) }
                seq.append(nil)
                continue
            }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            var adv = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &pos)
            CTRunGetAdvances(run, CFRange(), &adv)
            for k in 0..<n {
                guard let name = font.name(glyphs[k]), let def = font.glyph(name) else { seq.append(nil); continue }
                let drawn = def.strokes.contains { $0.kind != .other && !$0.points.isEmpty }
                if !drawn { seq.append(nil); continue }      // space and friends
                let o = P(x: Double(pos[k].x), y: Double(pos[k].y) + oy, r: 0)
                var refs: [Int] = []
                for s in def.strokes {
                    world.append(WorldStroke(kind: s.kind, points: s.points.map { $0 + o }, deferred: s.deferred, root: world.count))
                    refs.append(world.count - 1)
                }
                // Injector ends flow on along their target stroke.
                for (i, s) in def.strokes.enumerated() where s.kind == .open && (s.end["injector"] as? Bool ?? false) {
                    guard let t = s.end["snappingTarget"] as? Int, def.strokes.indices.contains(t) else { continue }
                    let T = def.strokes[t].points
                    switch def.strokes[t].kind {
                    case .open:
                        world[refs[i]].injection = Injection(curve: spline(T, lo: -1, hi: T.count - 3, n: 24).map { $0 + o },
                                                             closed: false, target: refs[t], follow: nil)
                    case .closed where T.count >= 3:
                        // A stroke that flows into a loop goes on round it; then on to
                        // where the next stroke on the loop starts (the tail of o).
                        let loop = spline(T + T.prefix(3), lo: 0, hi: T.count - 1, n: 24).dropLast().map { $0 + o }
                        let next = def.strokes.indices.first { $0 > i && (def.strokes[$0].start["snappingTarget"] as? Int) == t && !def.strokes[$0].points.isEmpty }
                        world[refs[i]].injection = Injection(curve: loop, closed: true, target: refs[t],
                                                             follow: next.map { def.strokes[$0].points[0] + o })
                    default:
                        break
                    }
                }
                seq.append(Inst(name: name, def: def, refs: refs, mark: adv[k].width < 1 && def.backward == nil && def.forward == nil))
            }
        }
        seq.append(nil)
    }
    if !missing.isEmpty {
        warn("not in the font, left out: " + String(missing.sorted()))
    }

    // Join each letter to the next one (skipping accents in between).
    var prev: Inst?
    for item in seq {
        guard let cur = item else { prev = nil; continue }
        if cur.mark { continue }
        if let a = prev, let fi = a.def.forward, let bi0 = cur.def.backward {
            let ai = find(a.refs[fi]), bi = find(cur.refs[bi0])
            let A = world[ai].points, B = world[bi].points
            if ai != bi && A.count >= 3 && B.count >= 3 {
                // the model works in the second letter's coordinates
                let ob = cur.refs.isEmpty ? P(x: 0, y: 0, r: 0) : P(x: world[cur.refs[bi0]].points[0].x - cur.def.strokes[bi0].points[0].x,
                                                                        y: world[cur.refs[bi0]].points[0].y - cur.def.strokes[bi0].points[0].y, r: 0)
                let q = joinPoints(exit: A.map { $0 - ob }, entry: B.map { $0 - ob }).map { $0 + ob }
                world[ai].points = Array(A.dropLast(3)) + q + Array(B.dropFirst(3))
                world[ai].injection = world[bi].injection
                world[bi].alive = false
                world[bi].root = ai
            }
        }
        prev = cur
    }

    // Strokes in writing order; deferred ones (i dots, t bars) at the end of
    // each word, as Apple writes them.
    var marks: [Mark] = []
    var pending: [Mark] = []
    var done = Set<Int>()
    func make(_ w: WorldStroke) -> Mark? {
        var pts: [P]
        switch w.kind {
        case .open:
            pts = spline(w.points, lo: -1, hi: w.points.count - 3, n: 40)
        case .closed:
            let F = w.points + w.points.prefix(3)
            pts = spline(F, lo: 0, hi: w.points.count - 1, n: 40)
        default:
            return nil
        }
        if let inj = w.injection, let end = pts.last, pts.count >= 2 {
            let c = inj.curve
            let near = { (p: P) in c.indices.min { hypot(c[$0].x - p.x, c[$0].y - p.y) < hypot(c[$1].x - p.x, c[$1].y - p.y) }! }
            let j = near(end)
            let d = (end.x - pts[pts.count - 2].x, end.y - pts[pts.count - 2].y)
            let n = c.count
            if inj.closed {
                // once round the loop, the way the stroke was heading, then on
                // to where the next stroke starts
                let tan = (c[(j + 1) % n].x - c[(j - 1 + n) % n].x, c[(j + 1) % n].y - c[(j - 1 + n) % n].y)
                let step = d.0 * tan.0 + d.1 * tan.1 >= 0 ? 1 : n - 1
                var k = j
                for _ in 0..<n { k = (k + step) % n; pts.append(c[k]) }
                if let f = inj.follow {
                    let kf = near(f)
                    var guardSteps = 0
                    while k != kf && guardSteps < n { k = (k + step) % n; pts.append(c[k]); guardSteps += 1 }
                }
            } else {
                let j1 = max(j - 1, 0), j2 = min(j + 1, n - 1)
                let tan = (c[j2].x - c[j1].x, c[j2].y - c[j1].y)
                let cont = d.0 * tan.0 + d.1 * tan.1 >= 0 ? Array(c[j...]) : Array(c[...j].reversed())
                if cont.count > 1 { pts += cont }
            }
        }
        pts = pts.map { P(x: $0.x, y: $0.y, r: $0.r * thickness) }
        var L = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) { L += hypot(b.x - a.x, b.y - a.y) }
        return Mark(points: pts, isDot: false, length: L)
    }
    for item in seq {
        guard let inst = item else {
            marks += pending; pending = []
            continue
        }
        for (i, s) in inst.def.strokes.enumerated() {
            if s.kind == .dot {
                let w = world[inst.refs[i]]
                for p in w.points {
                    let m = Mark(points: [P(x: p.x, y: p.y, r: p.r * thickness)], isDot: true, length: 2 * p.r * thickness)
                    if s.deferred { pending.append(m) } else { marks.append(m) }
                }
                continue
            }
            guard s.kind == .open || s.kind == .closed else { continue }
            let r = find(inst.refs[i])
            if done.contains(r) { continue }
            done.insert(r)
            // a loop this stroke goes round is drawn with it
            if let inj = world[r].injection, inj.closed { done.insert(find(inj.target)) }
            guard let m = make(world[r]) else { continue }
            if world[r].deferred { pending.append(m) } else { marks.append(m) }
        }
    }
    return marks + pending
}

