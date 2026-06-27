import SwiftUI

/// Decorative app backdrop — animated ASCII logo. Do not add foreground UI here.
/// Lives behind `ForegroundView` in `ContentView`; hit testing is disabled.
struct AsciiLogoBackground: View {
    /// When `false`, the backdrop renders a single static frame instead of redrawing every display
    /// frame via `TimelineView(.animation)` — which is what pins the CPU at idle. Animation code is
    /// kept fully intact; flip this on to resume the live animation. (Hidden by design; a runtime
    /// toggle will be wired up later.)
    private let animateBackground = false

    private let startDate = Date()

    private let maxRotation: Double = 15
    private let animationSpeed: Double = 0.0003
    private let breathingSpeed: Double = 0.0005
    private let breathingAmount: Double = 0.05

    var body: some View {
        Group {
            if animateBackground {
                TimelineView(.animation) { context in
                    let elapsedMs = context.date.timeIntervalSince(startDate) * 1000
                    logo(elapsedMs: elapsedMs)
                }
            } else {
                logo(elapsedMs: 0)
            }
        }
        .background(Color.white)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func logo(elapsedMs: Double) -> some View {
        let rotateX = sin(-elapsedMs * animationSpeed) * maxRotation
        let rotateY = cos(-elapsedMs * animationSpeed) * maxRotation
        let breathe = 1 + sin(elapsedMs * breathingSpeed) * breathingAmount
        let gradientShift = AsciiArtStyle.gradientShift(elapsedMs: elapsedMs)

        return ZStack {
            Color.white

            AsciiArtLabel(text: AsciiArt.logo, font: AppFont.ascii, gradientShift: gradientShift)
                .fixedSize(horizontal: true, vertical: true)
                .scaleEffect(breathe)
                .rotation3DEffect(.degrees(rotateX), axis: (x: 1, y: 0, z: 0), perspective: 0.001)
                .rotation3DEffect(.degrees(rotateY), axis: (x: 0, y: 1, z: 0), perspective: 0.001)
                .padding(.leading, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .clipped()
    }
}

#Preview {
    AsciiLogoBackground()
}
