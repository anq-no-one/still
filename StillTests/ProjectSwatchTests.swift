import AppKit
import Foundation
import Testing
@testable import Still

@MainActor
struct ProjectSwatchTests {
    @Test
    func aSwatchKeepsItsColorInsideAMenu() throws {
        let image = ProjectSwatch.platformImage(.blue)

        #expect(!image.isTemplate)
        let center = try #require(centerColor(of: image))
        let blue = try #require(NSColor.systemBlue.usingColorSpace(.sRGB))
        #expect(abs(center.redComponent - blue.redComponent) < 0.1)
        #expect(abs(center.greenComponent - blue.greenComponent) < 0.1)
        #expect(abs(center.blueComponent - blue.blueComponent) < 0.1)
    }

    @Test
    func theCurrentProjectSwatchIsMarked() throws {
        let plain = try #require(centerColor(of: ProjectSwatch.platformImage(.red)))
        let marked = try #require(centerColor(of: ProjectSwatch.platformImage(.red, selected: true)))

        #expect(marked.greenComponent > 0.9)
        #expect(plain.greenComponent < 0.5)
    }

    private func centerColor(of image: NSImage) -> NSColor? {
        let side = Int(ProjectSwatch.side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: side / 2, y: side / 2)?.usingColorSpace(.sRGB)
    }
}

struct MacEntitlementsTests {
    @Test
    func theMacAppCanWriteWhereTheUserChoosesToSave() throws {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Still/Still-macOS.entitlements")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any]
        )

        #expect(plist["com.apple.security.files.user-selected.read-write"] as? Bool == true)
    }
}
