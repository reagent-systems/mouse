import SwiftUI

@main
struct MouseApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            KeyboardFloatingHost { ContentView() }
                .ignoresSafeArea()
                .onAppear(perform: applyWindowMinimum)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { applyWindowMinimum() }
        }
    }

    /// iPad multitasking (Stage Manager) may resize the window; never let it shrink below an
    /// iPhone-sized canvas — the smallest layout the lane stack is designed for. iPhone scenes
    /// have no size restrictions (the property is nil there), so this is a no-op on phones.
    private func applyWindowMinimum() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 390, height: 700)
        }
    }
}

/// Hosts the app in a `UIHostingController` whose safe area excludes the keyboard region, so the
/// keyboard floats IN FRONT of the app (YouTube-style) and can never shift or resize it.
///
/// This is the one switch that actually works: SwiftUI-side `ignoresSafeArea(.keyboard)` cannot,
/// because `containerRelativeFrame` (which sizes the lane deck) measures the container itself,
/// and normal hosting shrinks that container for the keyboard at the source. Excluding the
/// keyboard from the hosting controller's `safeAreaRegions` stops the shrink before it exists.
/// Container safe areas (status bar, home indicator) still apply normally inside.
private struct KeyboardFloatingHost<Content: View>: UIViewControllerRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> KeyboardDismissCoordinator {
        KeyboardDismissCoordinator()
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = .container  // everything except the keyboard
        controller.view.backgroundColor = .clear

        // Tap anywhere outside a text input to dismiss the keyboard. Non-cancelling, so the
        // tapped thing (a file row, a button) still receives its tap; taps INSIDE text inputs
        // are filtered out so caret placement never fights dismissal; taps on the keyboard
        // itself live in a different window and never reach this recognizer.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(KeyboardDismissCoordinator.dismissKeyboard)
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        controller.view.addGestureRecognizer(tap)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
    }
}

/// Window regions where a tap must NOT dismiss the keyboard.
///
/// The dismiss recognizer below fires on any tap outside a text input, and for most of the app
/// that is the right reading of a tap. A terminal running a program is the exception: its key
/// strip and screen are buttons and output, not text inputs, yet tapping them is how the program
/// is DRIVEN — an arrow tap that also drops the keyboard makes a TUI menu undrivable one
/// keystroke at a time, which is exactly how it read on a phone. So the terminal registers its
/// frame while a program runs, and taps inside any registered region keep the keyboard. Taps
/// outside — another container, the gap between lanes — still dismiss, which is the half of the
/// rule worth keeping.
@MainActor
enum KeyboardHoldRegions {
    private static var frames: [UUID: CGRect] = [:]
    static func set(_ id: UUID, frame: CGRect) { frames[id] = frame }
    static func clear(_ id: UUID) { frames[id] = nil }
    static func contains(_ point: CGPoint) -> Bool {
        frames.values.contains { $0.contains(point) }
    }
}

final class KeyboardDismissCoordinator: NSObject, UIGestureRecognizerDelegate {
    @objc func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// Skip taps that land inside a text input (or one of its subviews), and taps inside a
    /// keyboard-hold region (a terminal with a program running — see [KeyboardHoldRegions]).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if KeyboardHoldRegions.contains(touch.location(in: nil)) { return false }
        var view = touch.view
        while let current = view {
            if current is UITextInput { return false }
            view = current.superview
        }
        return true
    }

    /// Coexist with every other gesture (SwiftUI taps, swipes, scrolls).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
