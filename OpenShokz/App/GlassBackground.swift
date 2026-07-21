import SwiftUI

// glassEffect exists only in the macOS 26 SDK (Xcode 26 / Swift 6.2+).
// The compiler guard keeps older toolchains (CI runners) building with the
// material fallback; the #available check picks the right look at runtime.

struct GlassBackground: View {
    var cornerRadius: CGFloat = 16

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

/// Transparent liquid-glass window fill (no tint color).
struct GlassWindowBackground: View {
    var body: some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(in: Rectangle())
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var fallback: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
    }
}
