import SwiftUI
import UIKit

struct AsciiArtLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    var gradientShift: CGFloat = 0

    func makeUIView(context: Context) -> AsciiArtTextView {
        let view = AsciiArtTextView(font: font)
        view.configure(text: text, font: font)
        context.coordinator.lastText = text
        context.coordinator.lastFont = font
        return view
    }

    func updateUIView(_ view: AsciiArtTextView, context: Context) {
        view.setGradientShift(gradientShift)

        if context.coordinator.lastText != text || context.coordinator.lastFont != font {
            view.configure(text: text, font: font)
            context.coordinator.lastText = text
            context.coordinator.lastFont = font
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastText: String?
        var lastFont: UIFont?
    }
}

final class AsciiArtTextView: UIView {
    private let textView = UITextView()
    private let gradientLayer = CAGradientLayer()
    private var gradientShift: CGFloat = 0
    private var textSize: CGSize = .zero

    init(font: UIFont) {
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false

        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(width: 10_000, height: 10_000)
        textView.layoutManager.usesFontLeading = false
        textView.font = font
        textView.textColor = .black

        gradientLayer.colors = AsciiArtStyle.desktopColors.map(\.cgColor)
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, font: UIFont) {
        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: AppFont.asciiParagraphStyle(for: font),
                .kern: 0,
                .baselineOffset: (font.pointSize * AppFont.asciiLineHeightFactor - font.lineHeight) / 2,
            ]
        )
        setNeedsLayout()
    }

    func setGradientShift(_ shift: CGFloat) {
        guard shift != gradientShift else { return }
        gradientShift = shift
        applyGradientFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        textSize = textView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textView.frame = CGRect(origin: .zero, size: textSize)
        textView.layoutIfNeeded()

        layer.mask = textView.layer
        textView.layer.frame = CGRect(origin: .zero, size: textSize)

        applyGradientFrame()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        textSize == .zero
            ? textView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            : textSize
    }

    private func applyGradientFrame() {
        guard textSize.width > 0, textSize.height > 0 else { return }
        gradientLayer.frame = CGRect(
            x: -gradientShift * textSize.width,
            y: 0,
            width: textSize.width * 2,
            height: textSize.height
        )
    }
}
