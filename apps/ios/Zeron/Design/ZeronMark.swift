import UIKit

/// The Zeron mark: rounded-square cells on a 820×940 grid (desktop logo).
/// The cell motif is the app's visual signature — status glyphs and loaders
/// are made of the same cells.
enum ZeronMark {
    static let cells: [(CGFloat, CGFloat)] = [
        (0, 600), (0, 720), (240, 840), (240, 720), (120, 840), (120, 600),
        (240, 600), (0, 480), (0, 360), (480, 840), (480, 720), (120, 360),
        (120, 240), (240, 360), (600, 720), (480, 600), (360, 360), (240, 240),
        (600, 600), (720, 600), (720, 480), (240, 120), (600, 380), (720, 240),
        (720, 0), (480, 240), (480, 0), (120, 480), (240, 480), (360, 840),
        (360, 720), (360, 600), (360, 480), (120, 720),
    ]

    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let scale = min(rect.width / 820, rect.height / 940)
        let dx = rect.minX + (rect.width - 820 * scale) / 2
        let dy = rect.minY + (rect.height - 940 * scale) / 2
        for (x, y) in cells {
            let cell = CGRect(x: dx + x * scale, y: dy + y * scale, width: 100 * scale, height: 100 * scale)
            path.addRoundedRect(in: cell, cornerWidth: 16 * scale, cornerHeight: 16 * scale)
        }
        return path
    }

    private static var cache: [CGFloat: UIImage] = [:]

    /// Template image (tint with the caller's color).
    static func image(side: CGFloat) -> UIImage {
        if let hit = cache[side] { return hit }
        let size = CGSize(width: side * 820 / 940, height: side)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            ctx.cgContext.addPath(path(in: CGRect(origin: .zero, size: size)))
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
        cache[side] = img
        return img
    }
}
