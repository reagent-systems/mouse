import UIKit

enum AppFont {
    static let asciiName = "IBMPlexMono-Bold"
    static let asciiSize: CGFloat = 12
    /// Matches CSS `line-height: 1` on the site — not multiplied against UIKit's default leading.
    static let asciiLineHeightFactor: CGFloat = 1.2

    static var ascii: UIFont {
        if let font = UIFont(name: asciiName, size: asciiSize) {
            return font
        }
        return .monospacedSystemFont(ofSize: asciiSize, weight: .bold)
    }

    static func asciiParagraphStyle(for font: UIFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let lineHeight = font.pointSize * asciiLineHeightFactor
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }
}
