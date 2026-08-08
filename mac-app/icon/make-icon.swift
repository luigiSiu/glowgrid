#!/usr/bin/env swift
//
// make-icon.swift - draw the app icon, rather than shipping a binary PNG.
//
//   swift make-icon.swift <output.iconset>
//
// Called by build.sh, which then runs iconutil to turn the .iconset into an
// .icns. Generating the artwork from code keeps the repository free of opaque
// binaries: the icon is reviewable, and tweaking a colour is a one-line diff
// instead of a re-export from some image editor.
//
// The picture is the thing itself: the 8x8 panel, lit with the same tick glyph
// and the same green the firmware uses for "available".

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The available icon, copied from GLYPH_TICK in status_ble/status_ble.ino.
// Row 0 is the top row; bit 7 is the leftmost column.
let tick: [UInt8] = [
    0b00000001,
    0b00000011,
    0b00000110,
    0b10001100,
    0b11011000,
    0b01110000,
    0b00110000,
    0b00100000,
]

func draw(size: CGFloat) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    /*
     * macOS icons are not edge to edge: the artwork sits inside a margin so
     * that icons of different shapes look the same weight in the Dock and
     * Finder. Roughly a tenth on each side matches Apple's own.
     */
    let margin = size * 0.09
    let body = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = body.width * 0.22

    // Dark body with a slight vertical gradient, so it reads as a physical
    // object rather than a flat square.
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.16, 0.17, 0.20, 1.0])!,
            CGColor(colorSpace: space, components: [0.06, 0.06, 0.08, 1.0])!,
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: body.maxY),
            end: CGPoint(x: 0, y: body.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Grid geometry: 8 cells across the inner area of the body.
    let inset = body.width * 0.10
    let grid = body.insetBy(dx: inset, dy: inset)
    let cell = grid.width / 8
    let dot = cell * 0.33

    let lit = CGColor(colorSpace: space, components: [0.20, 0.95, 0.35, 1.0])!
    let dim = CGColor(colorSpace: space, components: [1.0, 1.0, 1.0, 0.07])!

    for row in 0..<8 {
        for col in 0..<8 {
            let on = (tick[row] >> (7 - col)) & 1 == 1

            // Row 0 is the top of the glyph, but Core Graphics counts y from
            // the bottom, so the row index is flipped here.
            let centre = CGPoint(
                x: grid.minX + (CGFloat(col) + 0.5) * cell,
                y: grid.maxY - (CGFloat(row) + 0.5) * cell
            )

            if on {
                // A soft halo under each lit dot: real LEDs bleed into the
                // diffuser, and without it the icon looks like printed dots.
                if let glow = CGGradient(
                    colorsSpace: space,
                    colors: [
                        CGColor(colorSpace: space, components: [0.20, 0.95, 0.35, 0.55])!,
                        CGColor(colorSpace: space, components: [0.20, 0.95, 0.35, 0.0])!,
                    ] as CFArray,
                    locations: [0.0, 1.0]
                ) {
                    ctx.drawRadialGradient(
                        glow,
                        startCenter: centre, startRadius: 0,
                        endCenter: centre, endRadius: dot * 2.6,
                        options: []
                    )
                }
            }

            ctx.setFillColor(on ? lit : dim)
            ctx.fillEllipse(in: CGRect(
                x: centre.x - dot, y: centre.y - dot,
                width: dot * 2, height: dot * 2
            ))
        }
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2)
    }
}

// MARK: - main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// The exact set of names iconutil expects. Missing sizes make it fail with a
// terse error, so all ten are generated.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let image = draw(size: variant.pixels) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: out.appendingPathComponent(variant.name))
}
