import UIKit

enum AsciiArtStyle {
    static let gradientDuration: TimeInterval = 8

    static let desktopColors: [UIColor] = [
        UIColor(red: 0x2d / 255, green: 0x4a / 255, blue: 0x8a / 255, alpha: 1),
        UIColor(red: 0x80 / 255, green: 0x00 / 255, blue: 0x20 / 255, alpha: 1),
        UIColor(red: 0x2d / 255, green: 0x4a / 255, blue: 0x8a / 255, alpha: 1),
    ]

    /// CSS `gradient-shift`: 0% → 100% → 0% background-position over 8s linear.
    static func gradientShift(elapsedMs: Double) -> CGFloat {
        let progress = (elapsedMs / (gradientDuration * 1000)).truncatingRemainder(dividingBy: 1)
        if progress < 0.5 {
            return CGFloat(progress * 2)
        }
        return CGFloat((1 - progress) * 2)
    }
}
