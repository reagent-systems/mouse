import SwiftUI

struct AsciiLogoBackground: View {
    private let startDate = Date()

    private let maxRotation: Double = 15
    private let animationSpeed: Double = 0.0003
    private let breathingSpeed: Double = 0.0005
    private let breathingAmount: Double = 0.05

    var body: some View {
        TimelineView(.animation) { context in
            let elapsedMs = context.date.timeIntervalSince(startDate) * 1000
            let rotateX = sin(-elapsedMs * animationSpeed) * maxRotation
            let rotateY = cos(-elapsedMs * animationSpeed) * maxRotation
            let breathe = 1 + sin(elapsedMs * breathingSpeed) * breathingAmount
            let gradientShift = AsciiArtStyle.gradientShift(elapsedMs: elapsedMs)

            ZStack {
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
        .background(Color.white)
        .ignoresSafeArea()
    }
}

#Preview {
    AsciiLogoBackground()
}
