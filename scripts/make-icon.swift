// Draws the app icon and writes the icon set the bundle uses.
//
// Generated rather than drawn by hand so it can be changed in one place and
// re-rendered at every size:
//
//     swift scripts/make-icon.swift
//
// The mark is a rewind arc around a server rack: what the app does, in the one
// glyph that still reads at sixteen points.

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024.0
// Apple's grid for a macOS icon: the rounded square occupies 824 of 1024, and
// its corner radius is a little under a quarter of that.
let plateInset = (canvas - 824) / 2
let cornerRadius = 185.4

func context(size: Double) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: size / canvas, y: size / canvas)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

func colour(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let plate = CGRect(
    x: plateInset,
    y: plateInset,
    width: canvas - plateInset * 2,
    height: canvas - plateInset * 2
)

func drawPlate(_ context: CGContext) {
    let path = CGPath(roundedRect: plate, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [colour(44, 72, 122), colour(17, 29, 51)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: plate.maxY),
        end: CGPoint(x: 0, y: plate.minY),
        options: []
    )

    // A soft highlight along the top edge, which is what keeps a flat gradient
    // from looking like a sticker.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [colour(255, 255, 255, 0.20), colour(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: 0, y: plate.maxY),
        end: CGPoint(x: 0, y: plate.maxY - plate.height * 0.42),
        options: []
    )
    context.restoreGState()

    context.addPath(path)
    context.setStrokeColor(colour(255, 255, 255, 0.14))
    context.setLineWidth(6)
    context.strokePath()
}

/// A rear-view mirror, with what is behind you in the glass.
///
/// The name is the picture: hindsight is looking back at where you have been.
/// Inside the glass the racks recede toward a vanishing point up and to the
/// left — the server an hour ago, a day ago, a month ago — the nearest one lit.
/// Every other backup app draws a circular arrow; this one does not.
func drawMirror(_ context: CGContext, detailed: Bool) {
    let width = 616.0
    let height = 248.0
    let glass = CGRect(
        x: canvas / 2 - width / 2,
        y: canvas / 2 - height / 2 - 34,
        width: width,
        height: height
    )
    // Flattened, not a pill: the proportions are what make it a mirror.
    let corner = 58.0

    drawMount(context, glass: glass)

    let body = CGPath(roundedRect: glass, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.saveGState()
    context.addPath(body)
    context.clip()

    let depth = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [colour(8, 14, 28), colour(30, 46, 78)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        depth,
        start: CGPoint(x: glass.maxX, y: glass.minY),
        end: CGPoint(x: glass.minX, y: glass.maxY),
        options: []
    )

    drawReflection(context, glass: glass, detailed: detailed)

    context.setBlendMode(.screen)
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            colour(255, 255, 255, 0),
            colour(255, 255, 255, 0.13),
            colour(255, 255, 255, 0),
        ] as CFArray,
        locations: [0.0, 0.16, 0.44]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: glass.minX, y: glass.maxY),
        end: CGPoint(x: glass.midX, y: glass.minY),
        options: []
    )
    context.setBlendMode(.normal)
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.setLineWidth(detailed ? 26 : 34)
    context.replacePathWithStrokedPath()
    context.clip()
    let metal = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [colour(238, 243, 252), colour(142, 157, 184), colour(214, 223, 238)] as CFArray,
        locations: [0, 0.58, 1]
    )!
    context.drawLinearGradient(
        metal,
        start: CGPoint(x: 0, y: glass.maxY + 18),
        end: CGPoint(x: 0, y: glass.minY - 18),
        options: []
    )
    context.restoreGState()
}

/// The mount: a short tapered arm, which is what says "mirror" and not "pill".
func drawMount(_ context: CGContext, glass: CGRect) {
    let top = glass.maxY + 72
    let halfTop = 26.0
    let halfBottom = 54.0
    context.beginPath()
    context.move(to: CGPoint(x: canvas / 2 - halfBottom, y: glass.maxY - 10))
    context.addLine(to: CGPoint(x: canvas / 2 - halfTop, y: top))
    context.addLine(to: CGPoint(x: canvas / 2 + halfTop, y: top))
    context.addLine(to: CGPoint(x: canvas / 2 + halfBottom, y: glass.maxY - 10))
    context.closePath()
    context.setFillColor(colour(186, 198, 220))
    context.fillPath()

    let pad = CGRect(x: canvas / 2 - 48, y: top - 14, width: 96, height: 38)
    context.addPath(CGPath(roundedRect: pad, cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.setFillColor(colour(214, 223, 239))
    context.fillPath()
}

/// What the mirror shows: racks receding up and to the left, the way the road
/// behind you does. The nearest is bright and has its light on; the furthest is
/// nearly gone.
func drawReflection(_ context: CGContext, glass: CGRect, detailed: Bool) {
    struct Rack {
        var width: Double
        var height: Double
        var x: Double
        var y: Double
        var alpha: Double
    }

    let racks: [Rack] = detailed
        ? [
            Rack(width: 268, height: 54, x: 96, y: -58, alpha: 0.97),
            Rack(width: 176, height: 35, x: -2, y: 10, alpha: 0.50),
            Rack(width: 104, height: 22, x: -82, y: 62, alpha: 0.26),
        ]
        : [
            Rack(width: 300, height: 76, x: 64, y: -40, alpha: 0.97),
            Rack(width: 176, height: 46, x: -74, y: 56, alpha: 0.46),
        ]

    for (index, rack) in racks.enumerated() {
        let rect = CGRect(
            x: canvas / 2 + rack.x - rack.width / 2,
            y: glass.midY + rack.y - rack.height / 2,
            width: rack.width,
            height: rack.height
        )
        context.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: rack.height / 3,
                cornerHeight: rack.height / 3,
                transform: nil
            )
        )
        context.setFillColor(colour(228, 238, 254, rack.alpha))
        context.fillPath()

        guard detailed, index == 0 else { continue }
        let light = CGRect(x: rect.maxX - 46, y: rect.midY - 11, width: 22, height: 22)
        context.addEllipse(in: light)
        context.setFillColor(colour(86, 214, 140))
        context.fillPath()
    }
}

func render(size: Double) -> CGImage {
    let context = context(size: size)
    // What survives at this many pixels, not what looks best at 1024.
    let detailed = size >= 64
    drawPlate(context)
    drawMirror(context, detailed: detailed)
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("App/Hindsight/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes a macOS app icon has to carry, each at 1x and 2x.
let sizes = [16.0, 32, 128, 256, 512]
var entries: [[String: String]] = []
for size in sizes {
    for scale in [1.0, 2.0] {
        let pixels = size * scale
        let name = "icon_\(Int(size))x\(Int(size))\(scale == 2 ? "@2x" : "").png"
        try write(render(size: pixels), to: iconset.appendingPathComponent(name))
        entries.append([
            "filename": name,
            "idiom": "mac",
            "scale": "\(Int(scale))x",
            "size": "\(Int(size))x\(Int(size))",
        ])
    }
}

let contents: [String: Any] = [
    "images": entries,
    "info": ["author": "hindsight", "version": 1],
]
try JSONSerialization
    .data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))

// A standalone copy, for the readme and anywhere else a picture is wanted.
try write(render(size: 1024), to: root.appendingPathComponent("docs/icon.png"))
print("wrote \(entries.count) sizes to \(iconset.path)")
