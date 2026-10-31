// Renders Redi's app icon into Redi/Assets.xcassets/AppIcon.appiconset.
//
//   swift Scripts/make-icon.swift
//
// The design: a macOS-style squircle with a warm red gradient, three stacked white "slabs"
// (in-memory data), and a light streak suggesting speed. Drawn in code so it stays editable.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "Redi/Assets.xcassets/AppIcon.appiconset")

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: 824×824 body centred in 1024 with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1.00, green: 0.42, blue: 0.30, alpha: 1),
        CGColor(red: 0.87, green: 0.13, blue: 0.16, alpha: 1),
        CGColor(red: 0.55, green: 0.04, blue: 0.12, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // Speed streak.
    context.setFillColor(CGColor(gray: 1, alpha: 0.10))
    context.move(to: CGPoint(x: 100, y: 640))
    context.addLine(to: CGPoint(x: 924, y: 900))
    context.addLine(to: CGPoint(x: 924, y: 980))
    context.addLine(to: CGPoint(x: 100, y: 720))
    context.closePath()
    context.fillPath()

    // Three stacked slabs (isometric rounded rectangles), top one brightest.
    for (index, alpha) in [(0, 0.62), (1, 0.80), (2, 1.0)] {
        let y = 330 + CGFloat(index) * 125
        let slab = CGRect(x: 262, y: y, width: 500, height: 150)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.25))
        let path = CGMutablePath()
        // Parallelogram-ish slab: top face skewed for depth.
        path.move(to: CGPoint(x: slab.minX + 40, y: slab.minY))
        path.addLine(to: CGPoint(x: slab.maxX - 40, y: slab.minY))
        path.addQuadCurve(to: CGPoint(x: slab.maxX, y: slab.minY + 40), control: CGPoint(x: slab.maxX, y: slab.minY))
        path.addLine(to: CGPoint(x: slab.maxX, y: slab.maxY - 40))
        path.addQuadCurve(to: CGPoint(x: slab.maxX - 40, y: slab.maxY), control: CGPoint(x: slab.maxX, y: slab.maxY))
        path.addLine(to: CGPoint(x: slab.minX + 40, y: slab.maxY))
        path.addQuadCurve(to: CGPoint(x: slab.minX, y: slab.maxY - 40), control: CGPoint(x: slab.minX, y: slab.maxY))
        path.addLine(to: CGPoint(x: slab.minX, y: slab.minY + 40))
        path.addQuadCurve(to: CGPoint(x: slab.minX + 40, y: slab.minY), control: CGPoint(x: slab.minX, y: slab.minY))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: alpha))
        context.fillPath()
        context.restoreGState()
        // Indicator "LEDs" on each slab.
        context.setFillColor(CGColor(red: 0.87, green: 0.13, blue: 0.16, alpha: 0.9))
        for dot in 0..<3 {
            context.fillEllipse(in: CGRect(x: slab.minX + 48 + CGFloat(dot) * 46, y: slab.midY - 15, width: 30, height: 30))
        }
        context.setFillColor(CGColor(red: 0.55, green: 0.04, blue: 0.12, alpha: 0.35))
        context.fill(CGRect(x: slab.maxX - 210, y: slab.midY - 9, width: 160, height: 18))
    }
    context.restoreGState()

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
