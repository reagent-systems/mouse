import UIKit

enum AsciiArtStyle {
    static let gradientDuration: TimeInterval = 8

    /// Near-white tints of the site gradient (#2d4a8a → #800020) so the shift stays subtle on white.
    static let desktopColors: [UIColor] = [
        UIColor(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xFA / 255, alpha: 1),
        UIColor(red: 0xFA / 255, green: 0xF5 / 255, blue: 0xF6 / 255, alpha: 1),
        UIColor(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xFA / 255, alpha: 1),
    ]

    /// The same two hues, tinted near-DARK — slightly lighter than the dark canvas the way
    /// the light set is slightly darker than white, so the logo stays subtle in both.
    static let darkColors: [UIColor] = [
        UIColor(red: 0x30 / 255, green: 0x34 / 255, blue: 0x3E / 255, alpha: 1),
        UIColor(red: 0x3C / 255, green: 0x30 / 255, blue: 0x34 / 255, alpha: 1),
        UIColor(red: 0x30 / 255, green: 0x34 / 255, blue: 0x3E / 255, alpha: 1),
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
