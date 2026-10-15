// make-icon <dir.iconset>: writes the app icon at every size iconutil needs (build.sh then makes AppIcon.icns).
// Each size is drawn on its own rather than scaled down from 1024 px, so the small ones stay sharp.

import AppKit

@main
struct MakeIcon {
    static func main() {
        guard CommandLine.arguments.count == 2 else { fail("usage: make-icon <dir.iconset>") }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let image = StrataIcon.appIcon(pixels: points * scale),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { fail("make-icon: could not draw \(name)") }
                do { try png.write(to: dir.appendingPathComponent(name)) } catch { fail("make-icon: \(error)") }
            }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
