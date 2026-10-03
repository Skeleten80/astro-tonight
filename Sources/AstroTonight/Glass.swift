import SwiftUI

/// Frosted-glass card: translucent material, hairline highlight border,
/// and a soft top-light sheen — the glassmorphism look.
///
/// Built on materials rather than the macOS-26-only `glassEffect` API,
/// so it renders on every macOS back to the deployment target.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .overlay {
                // Top-light sheen, the tell-tale glass highlight.
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.10), .clear],
                        startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }
}

extension View {
    func glassPanel(radius: CGFloat = 14) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}
