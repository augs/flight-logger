// Renders the flight-logger app icon.
//
// Brief: "a plane and a log", Twin Peaks Log Lady as inspiration. The design
// puts the log end-on so the growth rings become the dominant shape — a set of
// concentric circles reads clearly at 40pt, where a side-on log would collapse
// into a brown smudge. The plane crosses it in white for maximum contrast
// against the wood.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])!
}

// MARK: - Background: night sky, so the white plane carries the silhouette.

let sky = CGGradient(
    colorsSpace: cs,
    colors: [rgb(18, 32, 54), rgb(38, 62, 92), rgb(58, 92, 122)] as CFArray,
    locations: [0, 0.6, 1]
)!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0), options: [])

// A few stars, small enough to survive downscaling without turning to mush.
ctx.setFillColor(rgb(255, 255, 255, 0.55))
for (x, y, r) in [(140.0, 840.0, 5.0), (250.0, 900.0, 3.5), (830.0, 880.0, 4.5),
                  (910.0, 780.0, 3.0), (170.0, 700.0, 3.0), (760.0, 940.0, 3.5)] {
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// MARK: - Log, end-on. Concentric rings are the recognisable element.

let centre = CGPoint(x: size / 2, y: size / 2)
let logRadius = 352.0

// Bark: a darker ring around the cut face.
ctx.setFillColor(rgb(74, 48, 32))
ctx.fillEllipse(in: CGRect(x: centre.x - logRadius, y: centre.y - logRadius,
                           width: logRadius * 2, height: logRadius * 2))

// Cut face.
let face = logRadius - 34
let wood = CGGradient(
    colorsSpace: cs,
    colors: [rgb(214, 168, 110), rgb(188, 138, 84)] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: centre.x - face, y: centre.y - face,
                          width: face * 2, height: face * 2))
ctx.clip()
ctx.drawRadialGradient(wood, startCenter: centre, startRadius: 0,
                       endCenter: centre, endRadius: face, options: [])

// Growth rings, slightly off-centre so it reads as timber rather than a target.
let heart = CGPoint(x: centre.x - 42, y: centre.y + 26)
ctx.setStrokeColor(rgb(150, 102, 58, 0.85))
for i in 1...7 {
    let r = Double(i) * (face / 7.6)
    ctx.setLineWidth(i % 2 == 0 ? 11 : 7)
    ctx.strokeEllipse(in: CGRect(x: heart.x - r, y: heart.y - r * 0.94,
                                 width: r * 2, height: r * 1.88))
}
ctx.restoreGState()

// MARK: - Plane, top view, crossing the log.

func planePath(scale s: Double) -> CGPath {
    let p = CGMutablePath()
    // Fuselage.
    p.addRoundedRect(in: CGRect(x: -0.085 * s, y: -0.62 * s, width: 0.17 * s, height: 1.24 * s),
                     cornerWidth: 0.085 * s, cornerHeight: 0.16 * s)
    // Main wings, swept back.
    p.move(to: CGPoint(x: -0.06 * s, y: 0.12 * s))
    p.addLine(to: CGPoint(x: -0.72 * s, y: -0.30 * s))
    p.addLine(to: CGPoint(x: -0.72 * s, y: -0.46 * s))
    p.addLine(to: CGPoint(x: -0.06 * s, y: -0.20 * s))
    p.closeSubpath()
    p.move(to: CGPoint(x: 0.06 * s, y: 0.12 * s))
    p.addLine(to: CGPoint(x: 0.72 * s, y: -0.30 * s))
    p.addLine(to: CGPoint(x: 0.72 * s, y: -0.46 * s))
    p.addLine(to: CGPoint(x: 0.06 * s, y: -0.20 * s))
    p.closeSubpath()
    // Tailplane.
    p.move(to: CGPoint(x: -0.05 * s, y: -0.44 * s))
    p.addLine(to: CGPoint(x: -0.30 * s, y: -0.62 * s))
    p.addLine(to: CGPoint(x: -0.30 * s, y: -0.70 * s))
    p.addLine(to: CGPoint(x: -0.05 * s, y: -0.60 * s))
    p.closeSubpath()
    p.move(to: CGPoint(x: 0.05 * s, y: -0.44 * s))
    p.addLine(to: CGPoint(x: 0.30 * s, y: -0.62 * s))
    p.addLine(to: CGPoint(x: 0.30 * s, y: -0.70 * s))
    p.addLine(to: CGPoint(x: 0.05 * s, y: -0.60 * s))
    p.closeSubpath()
    return p
}

ctx.saveGState()
ctx.translateBy(x: centre.x, y: centre.y)
ctx.rotate(by: -0.38)                      // banked, so it reads as flight
ctx.translateBy(x: 18, y: 26)

// Drop shadow lifts the plane off the wood at every size.
ctx.saveGState()
ctx.translateBy(x: 16, y: -18)
ctx.setFillColor(rgb(40, 26, 16, 0.35))
ctx.addPath(planePath(scale: 330))
ctx.fillPath()
ctx.restoreGState()

ctx.setFillColor(rgb(255, 255, 255))
ctx.addPath(planePath(scale: 330))
ctx.fillPath()
ctx.restoreGState()

// MARK: - Export

guard let image = ctx.makeImage() else { fatalError("image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("destination")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
