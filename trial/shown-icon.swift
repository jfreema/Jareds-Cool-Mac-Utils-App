// Trial only: writes an app's icon as Finder shows it, 512 pixels: swift trial/shown-icon.swift <app> <png>
import AppKit

let arguments = CommandLine.arguments
let image = NSWorkspace.shared.icon(forFile: arguments[1])
let pixels = 512
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: pixels / 2, height: pixels / 2)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: pixels / 2, height: pixels / 2))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
print("Wrote \(arguments[2]) from \(image.representations.map { "\($0.pixelsWide)" }.joined(separator: ", "))")
