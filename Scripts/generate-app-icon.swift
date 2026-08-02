#!/usr/bin/env swift
//
// Draws the VapourBox app icon and writes it as a PNG at any size.
//
// Vector source of truth, rendered natively — no ImageMagick or librsvg needed,
// and every size is drawn at its own scale rather than downsampled from one
// bitmap, so the 16px icon gets the same crisp edges as the 1024px one.
//
//   swift Scripts/generate-app-icon.swift --size 1024 --style macos --out icon.png
//
//   --style macos   rounded body inset in the canvas, per Apple's icon grid
//   --style square  full-bleed, for the Windows .ico and Linux
//
// THE DESIGN
//
// A frame mid-restoration, split the way the app's own before/after comparison
// splits it. Left of the divider is the source: dark, hazy, with scan lines torn
// sideways out of alignment — the comb artifact anyone with interlaced footage
// recognises on sight. Right of it the picture is whole: one continuous, clean
// image. The divider is the comparison handle.
//
// The haze on the damaged side is the nod to VapourSynth. It has no logo to
// borrow — its site header is a photograph — so the homage is to the name, and
// it earns its place by being the thing the app clears away rather than
// decoration.
//
// Two earlier attempts are worth recording so they are not repeated. Separate
// bars feeding a solid block read unmistakably as a mug of coffee with steam.
// Fading the torn lines into solid white made the restored half look blown out
// and skeletal, like a loading placeholder, because a restored picture is not
// white — it is coherent.
//
// Everything is a fraction of the canvas, so the composition is identical at
// every size. The haze and the grain are dropped below 64px, where they would be
// a few muddy pixels; the split and the torn lines carry it alone.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Arguments

var size = 1024
var style = "macos"
var outPath = "icon.png"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { break }
    let value = args.removeFirst()
    switch flag {
    case "--size": size = Int(value) ?? size
    case "--style": style = value
    case "--out": outPath = value
    default: break
    }
}

let S = CGFloat(size)
func u(_ f: CGFloat) -> CGFloat { f * S }

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// MARK: - Palette
//
// Navy body keyed off the app's blue seed. The restored half is a cool
// blue-to-cyan rise: bright enough to carry the silhouette on a light dock,
// coloured rather than white so it reads as a picture instead of a blank.

let navyDeep = rgb(8, 20, 44)
let navyMid = rgb(24, 62, 132)
let blueLift = rgb(44, 104, 214)
let screenDark = rgb(5, 13, 30)
let torn = rgb(116, 168, 250)        // misaligned scan lines
let cleanTop = rgb(126, 226, 255)    // restored picture, upper tone
let cleanBottom = rgb(232, 247, 255) // restored picture, lower tone
let haze = rgb(206, 230, 255)
let divider = rgb(255, 255, 255)

let ctxOpt = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
guard let ctx = ctxOpt else { fatalError("could not create bitmap context") }
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Body
//
// macOS 11+ puts the icon body in an 824/1024 rounded square and expects the
// remaining margin as breathing room. Windows and Linux want it full-bleed.

let isMac = (style == "macos")
let inset = isMac ? u(100.0 / 1024.0) : 0
let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner = isMac ? u(185.4 / 1024.0) : u(0.16)
let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner,
                      transform: nil)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: sRGB, colors: [navyMid, navyDeep] as CFArray,
               locations: [0, 1])!,
    start: CGPoint(x: body.minX, y: body.maxY),
    end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.drawRadialGradient(
    CGGradient(colorsSpace: sRGB,
               colors: [blueLift.copy(alpha: 0.5)!, blueLift.copy(alpha: 0)!] as CFArray,
               locations: [0, 1])!,
    startCenter: CGPoint(x: body.minX + body.width * 0.26, y: body.maxY - body.height * 0.1),
    startRadius: 0,
    endCenter: CGPoint(x: body.minX + body.width * 0.26, y: body.maxY - body.height * 0.1),
    endRadius: body.width * 0.8, options: [])
ctx.restoreGState()

// MARK: - Screen

let screen = CGRect(
    x: body.minX + body.width * 0.105,
    y: body.minY + body.height * 0.225,
    width: body.width * 0.790,
    height: body.height * 0.550)
let screenRadius = screen.height * 0.115
let screenPath = CGPath(roundedRect: screen, cornerWidth: screenRadius,
                        cornerHeight: screenRadius, transform: nil)

ctx.addPath(screenPath)
ctx.setFillColor(screenDark)
ctx.fillPath()

ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()

// The split. Tilted a few degrees off vertical so the icon has some motion in
// it and does not read as a two-pane layout.
let splitX = screen.minX + screen.width * 0.455
let lean = screen.width * 0.055
let splitPath = CGMutablePath()
splitPath.move(to: CGPoint(x: splitX - lean, y: screen.minY))
splitPath.addLine(to: CGPoint(x: screen.maxX, y: screen.minY))
splitPath.addLine(to: CGPoint(x: screen.maxX, y: screen.maxY))
splitPath.addLine(to: CGPoint(x: splitX + lean, y: screen.maxY))
splitPath.closeSubpath()

// Restored half: a continuous image, drawn as a smooth tonal rise. Nothing in
// here is striped — that is the whole point of the right-hand side.
ctx.saveGState()
ctx.addPath(splitPath)
ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: sRGB, colors: [cleanBottom, cleanTop] as CFArray,
               locations: [0, 1])!,
    start: CGPoint(x: screen.midX, y: screen.minY),
    end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
ctx.restoreGState()

// Damaged half: scan lines torn sideways, each by a different amount, the tear
// alternating direction so it reads as misalignment and not as a slope. They run
// off the left edge of the screen, as a real comb artifact does.
let lineCount = 5
let pitch = screen.height / CGFloat(lineCount)
let lineH = pitch * 0.56
let tears: [CGFloat] = [0.26, 0.06, 0.34, 0.14, 0.22]

ctx.saveGState()
// Clip to the damaged side only, so no torn line crosses the divider.
let damaged = CGMutablePath()
damaged.move(to: CGPoint(x: screen.minX, y: screen.minY))
damaged.addLine(to: CGPoint(x: splitX - lean, y: screen.minY))
damaged.addLine(to: CGPoint(x: splitX + lean, y: screen.maxY))
damaged.addLine(to: CGPoint(x: screen.minX, y: screen.maxY))
damaged.closeSubpath()
ctx.addPath(damaged)
ctx.clip()

for i in 0..<lineCount {
    let y = screen.minY + CGFloat(i) * pitch + (pitch - lineH) * 0.5
    let left = screen.minX - screen.width * 0.06 + screen.width * tears[i]
    let rect = CGRect(x: left, y: y, width: screen.width, height: lineH)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lineH * 0.5,
                       cornerHeight: lineH * 0.5, transform: nil))
    // Slightly dimmer further from the divider: the eye travels toward the fix.
    ctx.setFillColor(torn.copy(alpha: 0.80 + 0.07 * CGFloat(i % 3))!)
    ctx.fillPath()
}

// Haze over the damaged side, thickest at the far edge and thinning as it
// approaches the divider — the vapour being cleared.
if size >= 64 {
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: sRGB,
                   colors: [haze.copy(alpha: 0.40)!, haze.copy(alpha: 0.02)!] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: screen.minX, y: screen.midY),
        end: CGPoint(x: splitX, y: screen.midY), options: [])
}
// A soft sheen across the restored half, so it reads as an image with light in
// it rather than a flat fill. Subtle enough to vanish by 32px.
if size >= 64 {
    ctx.saveGState()
    ctx.addPath(splitPath)
    ctx.clip()
    ctx.drawRadialGradient(
        CGGradient(colorsSpace: sRGB,
                   colors: [divider.copy(alpha: 0.55)!, divider.copy(alpha: 0)!] as CFArray,
                   locations: [0, 1])!,
        startCenter: CGPoint(x: screen.maxX - screen.width * 0.13,
                             y: screen.maxY - screen.height * 0.10),
        startRadius: 0,
        endCenter: CGPoint(x: screen.maxX - screen.width * 0.13,
                           y: screen.maxY - screen.height * 0.10),
        endRadius: screen.width * 0.46, options: [])
    ctx.restoreGState()
}

ctx.restoreGState()

// The comparison handle.
let handle = CGMutablePath()
handle.move(to: CGPoint(x: splitX - lean, y: screen.minY))
handle.addLine(to: CGPoint(x: splitX + lean, y: screen.maxY))
ctx.addPath(handle)
ctx.setStrokeColor(divider.copy(alpha: 0.92)!)
ctx.setLineWidth(max(1, screen.width * 0.022))
ctx.strokePath()

ctx.restoreGState()

// Hairline around the screen, and around the body on macOS, so neither
// dissolves into a dark dock.
ctx.addPath(screenPath)
ctx.setStrokeColor(rgb(255, 255, 255, 0.14))
ctx.setLineWidth(max(1, u(2.5 / 1024.0)))
ctx.strokePath()

if isMac {
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.09))
    ctx.setLineWidth(max(1, u(2.0 / 1024.0)))
    ctx.strokePath()
}

// MARK: - Write

guard let image = ctx.makeImage() else { fatalError("could not render image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outPath))
FileHandle.standardError.write("  \(outPath) (\(size)px, \(style))\n".data(using: .utf8)!)
