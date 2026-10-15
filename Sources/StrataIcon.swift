// The Strata icon ("Sediment Bands"): a rounded tile cut by three wavy rock layers.
// Drawn in code, shared by the menu bar glyph (a template image, so macOS tints it for light and dark menu bars)
// and the app icon that build.sh renders into AppIcon.icns. Coordinates are a 24 x 24 grid, y down.

import AppKit

enum StrataIcon {
    enum Glyph { case loaded, paused, busy(Int), stopped }

    static let tile = CGRect(x: 3, y: 3, width: 18, height: 18)
    static let tileRadius: CGFloat = 5

    static let top: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 2))
        p.addLine(to: CGPoint(x: 22, y: 2))
        p.addLine(to: CGPoint(x: 22, y: 8.2))
        p.addCurve(to: CGPoint(x: 12, y: 8.4), control1: CGPoint(x: 18.5, y: 6.6), control2: CGPoint(x: 15.5, y: 9.6))
        p.addCurve(to: CGPoint(x: 2, y: 8.2), control1: CGPoint(x: 8.5, y: 7.2), control2: CGPoint(x: 5.5, y: 9.4))
        p.closeSubpath()
        return p
    }()

    static let middle: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 10.2))
        p.addCurve(to: CGPoint(x: 12, y: 10.4), control1: CGPoint(x: 5.5, y: 11.4), control2: CGPoint(x: 8.5, y: 9.2))
        p.addCurve(to: CGPoint(x: 22, y: 10.2), control1: CGPoint(x: 15.5, y: 11.6), control2: CGPoint(x: 18.5, y: 8.6))
        p.addLine(to: CGPoint(x: 22, y: 14.4))
        p.addCurve(to: CGPoint(x: 12, y: 14.6), control1: CGPoint(x: 18.5, y: 13.2), control2: CGPoint(x: 15.5, y: 15.6))
        p.addCurve(to: CGPoint(x: 2, y: 14.4), control1: CGPoint(x: 8.5, y: 13.6), control2: CGPoint(x: 5.5, y: 15.6))
        p.closeSubpath()
        return p
    }()

    static let bottom: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 16.4))
        p.addCurve(to: CGPoint(x: 12, y: 16.6), control1: CGPoint(x: 5.5, y: 17.6), control2: CGPoint(x: 8.5, y: 15.6))
        p.addCurve(to: CGPoint(x: 22, y: 16.4), control1: CGPoint(x: 15.5, y: 17.6), control2: CGPoint(x: 18.5, y: 15.2))
        p.addLine(to: CGPoint(x: 22, y: 22))
        p.addLine(to: CGPoint(x: 2, y: 22))
        p.closeSubpath()
        return p
    }()

    static var layers: [CGPath] { [top, middle, bottom] }

    // MARK: menu bar

    /// The 18 pt menu bar glyph: loaded = all layers, paused = the top layer hollow (the model is unloaded),
    /// busy = the layers fill from the bottom up (frame 0, 1, 2, 3, ...), stopped = all layers dimmed.
    static func menuBarImage(_ glyph: Glyph) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.scaleBy(x: rect.width / 24, y: rect.height / 24)
            cg.setFillColor(NSColor.black.cgColor)
            cg.setStrokeColor(NSColor.black.cgColor)
            let filled: [CGPath]
            var outlined = true
            switch glyph {
            case .loaded:
                filled = layers
                outlined = false
            case .paused:
                filled = [middle, bottom]
            case .busy(let frame):
                filled = [[bottom], [middle, bottom], layers, []][frame % 4]
            case .stopped:
                filled = layers
                outlined = false
                cg.setAlpha(0.35)
            }
            if outlined {
                let edge = tile.insetBy(dx: 0.65, dy: 0.65)
                cg.addPath(CGPath(roundedRect: edge, cornerWidth: 4.4, cornerHeight: 4.4, transform: nil))
                cg.setLineWidth(1.3)
                cg.strokePath()
            }
            cg.addPath(CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil))
            cg.clip()
            for layer in filled { cg.addPath(layer) }
            cg.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: app icon

    /// The app icon at `pixels` x `pixels`: macOS's 824-unit tile with 100-unit margins on a 1024 canvas.
    static func appIcon(pixels: Int) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(pixels) / 1024
        cg.translateBy(x: 0, y: CGFloat(pixels))
        cg.scaleBy(x: s, y: -s)                                          // y down, as the grid

        let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

        cg.saveGState()                                                  // the shadow under the tile
        cg.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.28))
        cg.addPath(tilePath)
        cg.setFillColor(rgb(0xE6DED2))
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(tilePath)
        cg.clip()
        fill(cg, gradient: [0xF7F3EC, 0xE6DED2], from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
        let k = tileRect.width / tile.width                              // the grid's tile onto the icon's tile
        cg.translateBy(x: tileRect.minX - tile.minX * k, y: tileRect.minY - tile.minY * k)
        cg.scaleBy(x: k, y: k)
        let bands: [(CGPath, [UInt32], Bool)] = [
            (top, [0xFFD59A, 0xF0A85A], true),                           // sand, diagonal
            (middle, [0xE98A6A, 0xC8603F], false),                       // clay
            (bottom, [0x7EA0E6, 0x4F6FBF], false),                       // slate
        ]
        for (path, colors, diagonal) in bands {
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            let b = path.boundingBox
            fill(cg, gradient: colors, from: CGPoint(x: b.minX, y: b.minY),
                 to: CGPoint(x: b.maxX, y: diagonal ? b.maxY : b.minY))
            cg.restoreGState()
        }
        cg.restoreGState()
        return cg.makeImage()
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func fill(_ cg: CGContext, gradient hexes: [UInt32], from: CGPoint, to: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: hexes.map(rgb) as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: from, end: to,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
