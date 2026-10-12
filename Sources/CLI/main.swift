// glassstroke: write text in Apple's hello handwriting as 3D glass.
import AppKit
import CoreGraphics
import Foundation
import GlassStroke

let usage = """
usage: glassstroke <text> -o <output> [options]
       glassstroke --symbol <SF Symbol name> -o <output> [options]

Writes <text> in Apple's "hello" handwriting as glass, refracting a backdrop
image (your desktop picture unless you pick one). The output type follows
the extension:
  .png   the finished text; with --frames, a folder of numbered frames;
         with --animated, an animated PNG (keeps soft transparency)
  .mov   the write-on animation; with --transparent, ProRes 4444 with alpha
  .mp4   the write-on animation (H.264)
  .gif   the write-on animation, looping

options:
  --backdrop IMG     image seen through and behind the glass
  --size PX          em size in pixels (default 240)
  --width W --height H
                     image size (default: the text plus a margin)
  --weight N         pen weight, 100 (Thin) to 900 (Black); 500 is Apple's
  --transparent      glass only, transparent around it
  --duration S       seconds of writing (default: the hello screen's pen speed)
  --curve C          hello (default), linear, ease-in-out, or cubic-bezier(x1,y1,x2,y2)
  --fps N            frames per second (default 60; GIF 30)
  --delay S          blank time before the pen starts (default 0)
  --hold S           time the finished text stays (default 1.5)
  --time S           for a .png: the moment to show (default: when the writing ends)
  --frames           .png: write every frame into a folder
  --refraction D     lensing strength (default 2000, in font units)
  --dispersion X     rainbow fringes (default 0.02)
  --light-speed R    key light, radians per second (default 0.657)
  --font PATH        Macintosh Skeletal font to read (default: the one in macOS)
  --symbol NAME      an SF Symbol as puffed glass instead of text
  --edge X           symbol: glass thickness scale (default 1: round like a pen tube)
  --draw             symbol: write it on in glass with SF Symbols' own Draw On
                     animation (its designed draw paths and timing)
  --draw-guess       symbol: write it on in an automatic order instead

Text can have several lines: put \\n between them.
"""

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(("glassstroke: " + s + "\n").data(using: .utf8)!)
    exit(1)
}

func bezier(_ s: String) -> (@Sendable (Double) -> Double)? {
    let t = s.lowercased().replacingOccurrences(of: " ", with: "")
    let named: [String: [Double]] = ["linear": [0, 0, 1, 1], "ease": [0.25, 0.1, 0.25, 1], "ease-in": [0.42, 0, 1, 1],
                                     "ease-out": [0, 0, 0.58, 1], "ease-in-out": [0.42, 0, 0.58, 1]]
    if t == "hello" { return HelloHandwriting.progress(at:) }
    var v = named[t]
    if v == nil, t.hasPrefix("cubic-bezier("), t.hasSuffix(")") {
        v = t.dropFirst(13).dropLast().split(separator: ",").compactMap { Double($0) }
    }
    guard let c = v, c.count == 4 else { return nil }
    let (x1, y1, x2, y2) = (c[0], c[1], c[2], c[3])
    return { x in
        func b(_ t: Double, _ a: Double, _ c: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * c + t * t * t }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 { let m = (lo + hi) / 2; if b(m, x1, x2) < x { lo = m } else { hi = m } }
        return b((lo + hi) / 2, y1, y2)
    }
}

/// A soft colourful backdrop for when there's no desktop picture.
func fallbackBackdrop() -> CGImage {
    let w = 1600, h = 1000
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [CGColor(srgbRed: 0.98, green: 0.62, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.98, green: 0.85, blue: 0.5, alpha: 1),
                  CGColor(srgbRed: 0.55, green: 0.9, blue: 0.75, alpha: 1), CGColor(srgbRed: 0.5, green: 0.7, blue: 0.98, alpha: 1),
                  CGColor(srgbRed: 0.78, green: 0.6, blue: 0.98, alpha: 1)] as CFArray
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 0.25, 0.5, 0.75, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    return ctx.makeImage()!
}

func desktopPicture() -> CGImage? {
    guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
    return try? loadImage(url)
}

// MARK: - Options

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { print(usage); exit(args.isEmpty ? 1 : 0) }
var text: [String] = []
var output = "", backdropPath: String?, fontPath = HelloHandwriting.systemFontPath
var size: Float = 240, width: Int?, height: Int?, weight: Float = 500
var transparent = false, frames = false, animated = false
var duration: Double?, fps: Double?, delay = 0.0, hold = 1.5, still: Double?
var timing: (@Sendable (Double) -> Double) = HelloHandwriting.progress(at:)
var style = GlassStyle()
var symbol: String?, edge: Double?, drawOn = false, drawGuess = false, curveSet = false
func value(_ n: String) -> String { guard !args.isEmpty else { fail("\(n) needs a value") }; return args.removeFirst() }
func num(_ n: String) -> Double { let v = value(n); guard let d = Double(v) else { fail("\(n): not a number: \(v)") }; return d }
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-o", "--output": output = value(a)
    case "--backdrop": backdropPath = value(a)
    case "--size": size = Float(num(a))
    case "--width": width = Int(num(a))
    case "--height": height = Int(num(a))
    case "--weight": weight = Float(num(a))
    case "--transparent": transparent = true
    case "--frames": frames = true
    case "--animated": animated = true
    case "--duration": duration = num(a)
    case "--fps": fps = num(a)
    case "--delay": delay = num(a)
    case "--hold": hold = num(a)
    case "--time": still = num(a)
    case "--curve": let v = value(a); guard let c = bezier(v) else { fail("unknown curve \(v)") }; timing = c; curveSet = true
    case "--refraction": style.refractionDistance = Float(num(a))
    case "--dispersion": style.dispersion = Float(num(a))
    case "--light-speed": style.lightSpeed = Float(num(a))
    case "--font": fontPath = value(a)
    case "--symbol": symbol = value(a)
    case "--edge": edge = num(a)
    case "--draw": drawOn = true
    case "--draw-guess": drawGuess = true
    default:
        if a.hasPrefix("--") { fail("unknown option \(a) (see --help)") }
        text.append(a)
    }
}
guard !text.isEmpty || symbol != nil else { fail("no text given (see --help)") }
guard !output.isEmpty else { fail("no output file given: -o <file>") }

// MARK: - Render

do {
  if let name = symbol {
    var recorded: GlassShape?
    if drawOn {
        guard #available(macOS 26.0, *) else { fail("--draw needs macOS 26 (SF Symbols Draw On); try --draw-guess") }
        recorded = MainActor.assumeIsolated { GlassShape.symbolDrawOn(name, size: 1000) }
        if recorded == nil { fail("couldn't record the Draw On animation of \(name)") }
    }
    guard var shape = recorded ?? GlassShape.symbol(name, size: 1000) else { fail("no SF Symbol named \(name)") }
    if let e = edge { shape.thickness = Float(e) }
    let backdrop = try backdropPath.map { try loadImage(URL(fileURLWithPath: $0)) } ?? desktopPicture() ?? fallbackBackdrop()
    let upp = 1000 / size
    let b = shape.bounds
    let W = width ?? Int((Float(b.width) * 1.3 / upp).rounded(.up)), H = height ?? Int((Float(b.height) * 1.3 / upp).rounded(.up))
    let placement = Placement(unitsPerPixel: upp, origin: SIMD2(Float(b.midX) - Float(W) / 2 * upp, Float(b.midY) - Float(H) / 2 * upp))
    if drawGuess { shape = shape.withDrawOrder() }
    let writing = drawOn || drawGuess
    // recorded: the order is Apple's own timeline in seconds (already eased)
    let natural: Double = drawOn ? Double(shape.orderLength) : Double(shape.orderLength) / HelloHandwriting.penSpeed
    let writeTime: Double = writing ? (duration ?? natural) : 0
    var anim = GlassAnimation(segments: [], backdrop: backdrop, width: W, height: H, placement: placement, duration: writeTime)
    anim.shape = shape
    anim.style = style
    let linear: @Sendable (Double) -> Double = { $0 }
    anim.timing = drawOn && !curveSet ? linear : timing
    anim.delay = delay
    anim.hold = writing ? hold : (duration ?? 4)
    anim.opaque = !transparent
    anim.fps = fps ?? (output.lowercased().hasSuffix(".gif") ? 30 : 60)
    let renderer = try GlassRenderer()
    let url = URL(fileURLWithPath: output)
    switch url.pathExtension.lowercased() {
    case "png" where frames: try anim.writeFrames(to: url.deletingPathExtension(), renderer: renderer)
    case "png" where animated: try anim.writeAPNG(to: url, renderer: renderer)
    case "png": try writePNG(anim.frame(at: still ?? anim.delay + anim.duration, renderer: renderer), to: url)
    case "mov", "mp4": try anim.writeMovie(to: url, renderer: renderer)
    case "gif": try anim.writeGIF(to: url, renderer: renderer)
    default: fail("unknown output type: use .png, .mov, .mp4 or .gif")
    }
    print("\(output) (\(W)x\(H))")
    exit(0)
  }
    let (drawing, missing) = try HelloHandwriting.drawing(text.joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n"),
                                                          weight: weight, fontPath: fontPath)
    if !missing.isEmpty { FileHandle.standardError.write("glassstroke: not in the font, left out: \(missing)\n".data(using: .utf8)!) }
    guard !drawing.strokes.isEmpty else { fail("nothing to write") }
    let backdrop = try backdropPath.map { try loadImage(URL(fileURLWithPath: $0)) } ?? desktopPicture() ?? fallbackBackdrop()

    let upp = 1000 / size
    let b = drawing.bounds
    let margin = Float(0.35) * 1000
    let W = width ?? Int(((Float(b.width) + 2 * margin) / upp).rounded(.up))
    let H = height ?? Int(((Float(b.height) + 2 * margin) / upp).rounded(.up))
    let placement = Placement(unitsPerPixel: upp,
                              origin: SIMD2(Float(b.midX) - Float(W) / 2 * upp, Float(b.midY) - Float(H) / 2 * upp))
    let length = drawing.strokes.reduce(Float(0)) { $0 + ($1.points.count < 2 ? 2 * ($1.points.first?.radius ?? 0) : $1.length) }
    let ext = (output as NSString).pathExtension.lowercased()
    var anim = GlassAnimation(segments: drawing.segments(), backdrop: backdrop, width: W, height: H, placement: placement,
                              duration: duration ?? Double(length) / HelloHandwriting.penSpeed)
    anim.style = style
    anim.delay = delay
    anim.hold = hold
    anim.timing = timing
    anim.opaque = !transparent
    anim.fps = fps ?? (ext == "gif" || animated ? 30 : 60)
    let renderer = try GlassRenderer()
    let url = URL(fileURLWithPath: output)
    let started = Date()
    switch ext {
    case "png" where frames:
        try anim.writeFrames(to: url.deletingPathExtension(), renderer: renderer)
    case "png" where animated:
        try anim.writeAPNG(to: url, renderer: renderer)
    case "png":
        try writePNG(anim.frame(at: still ?? anim.delay + anim.duration, renderer: renderer), to: url)
    case "mov", "mp4":
        try anim.writeMovie(to: url, renderer: renderer)
    case "gif":
        try anim.writeGIF(to: url, renderer: renderer)
    default:
        fail("unknown output type .\(ext): use .png, .mov, .mp4 or .gif")
    }
    print(String(format: "%@ (%dx%d, %.1f s of animation, rendered in %.1f s)", output, W, H, anim.totalDuration, Date().timeIntervalSince(started)))
} catch {
    fail("\(error)")
}
