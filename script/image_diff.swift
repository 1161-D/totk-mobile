// Compare two same-sized screenshots: mean absolute channel difference and the share of pixels differing by more than a threshold.
// Usage: swift script/image_diff.swift a.png b.png [threshold=24] [heatmap.png]
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ path: String) -> (Int, Int, [UInt8]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(path)") }
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height, data)
}

let arguments = CommandLine.arguments
let threshold = arguments.count > 3 ? Int(arguments[3])! : 24
let (wa, ha, a) = pixels(arguments[1]), (wb, hb, b) = pixels(arguments[2])
guard wa == wb && ha == hb else { fatalError("sizes differ: \(wa)x\(ha) vs \(wb)x\(hb)") }
var total = 0, changed = 0
for i in stride(from: 0, to: a.count, by: 4) {
    var largest = 0
    for c in 0..<3 { let d = abs(Int(a[i + c]) - Int(b[i + c])); total += d; largest = max(largest, d) }
    if largest > threshold { changed += 1 }
}
let count = wa * ha
if arguments.count > 4 {   // Per-pixel largest channel difference, amplified 8x, as a grey image.
    var heat = [UInt8](repeating: 0, count: count)
    for i in 0..<count { var largest = 0; for c in 0..<3 { largest = max(largest, abs(Int(a[4 * i + c]) - Int(b[4 * i + c]))) }; heat[i] = UInt8(min(255, largest * 8)) }
    let context = CGContext(data: &heat, width: wa, height: ha, bitsPerComponent: 8, bytesPerRow: wa, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[4]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
}
print(String(format: "mean_abs_diff=%.3f changed_pct=%.3f (threshold %d, %dx%d)", Double(total) / Double(count * 3),
             Double(changed) * 100 / Double(count), threshold, wa, ha))
