import SwiftUI

/// Interactive app UI — panels, navigation, controls. Stacks above `AsciiLogoBackground`.
struct ForegroundView: View {
    var body: some View {
        EmptyView()
    }
}

#Preview {
    ZStack {
        AsciiLogoBackground()
        ForegroundView()
    }
}
