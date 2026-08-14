import SwiftUI

/// The little sphere of dots that turns while the agent is doing something.
///
/// After the `thinking-orbs` component by Jakub Antalik and Alex Brinza
/// (orbs.jakubantalik.com) — the idea and the visual language are theirs. That component is
/// React on npm and cannot be imported here, so this is the same thing built natively: points
/// on a sphere, rotated and projected each frame, drawn in one `Canvas`.
///
/// Monochrome on purpose. Every other surface in this app is white on black in one mono face,
/// and a colour gradient here would be the only thing in the ring shouting.
struct ThinkingOrb: View {
    enum State {
        /// Nothing happening — the orb rests, barely turning.
        case idle
        /// The microphone is open.
        case listening
        /// The agent is working.
        case working

        /// Turns per second.
        var speed: Double {
            switch self {
            case .idle: return 0.08
            case .listening: return 0.35
            case .working: return 0.55
            }
        }

        /// How far the sphere breathes, as a fraction of its radius.
        var breath: Double {
            switch self {
            case .idle: return 0.02
            case .listening: return 0.10
            case .working: return 0.05
            }
        }
    }

    var state: State = .idle
    var size: CGFloat = 18

    /// Points on the sphere, once. A Fibonacci lattice spaces them evenly, which a naive
    /// lat/long grid does not — that bunches everything at the poles and reads as two bright
    /// caps with a bald equator.
    private static let points: [SIMD3<Double>] = {
        let count = 96
        let golden = Double.pi * (3 - (5.0).squareRoot())
        return (0..<count).map { i in
            let y = 1 - (Double(i) / Double(count - 1)) * 2
            let radius = max(0, 1 - y * y).squareRoot()
            let theta = golden * Double(i)
            return SIMD3(cos(theta) * radius, y, sin(theta) * radius)
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let breathing = 1 + sin(t * 2.2) * state.breath
                let radius = min(canvasSize.width, canvasSize.height) / 2 * 0.86 * breathing
                let spin = t * state.speed * 2 * .pi
                // A fixed tilt so the poles are visible and the rotation reads as a SPHERE
                // rather than a flat ring of dots.
                let tilt = 0.42
                for point in Self.points {
                    let x = point.x * cos(spin) + point.z * sin(spin)
                    let z = -point.x * sin(spin) + point.z * cos(spin)
                    let y = point.y * cos(tilt) - z * sin(tilt)
                    let depth = point.y * sin(tilt) + z * cos(tilt)
                    // Depth does the work: near dots are larger and brighter, far ones fade.
                    // Without it the projection is a disc, not a ball.
                    let near = (depth + 1) / 2
                    let dot = CGSize(width: 0.9 + near * 1.1, height: 0.9 + near * 1.1)
                    let position = CGPoint(x: centre.x + x * radius, y: centre.y + y * radius)
                    let rect = CGRect(
                        x: position.x - dot.width / 2, y: position.y - dot.height / 2,
                        width: dot.width, height: dot.height)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(.white.opacity(0.18 + near * 0.62)))
                }
            }
            .frame(width: size, height: size)
        }
        .allowsHitTesting(false)
    }
}

/// The orb with its word, in the pill the reference puts it in.
struct ThinkingOrbLabel: View {
    let state: ThinkingOrb.State
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ThinkingOrb(state: state, size: 18)
            Text(text)
                .font(.custom(AppFont.asciiName, size: 12))
                .opacity(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: Capsule())
    }
}
