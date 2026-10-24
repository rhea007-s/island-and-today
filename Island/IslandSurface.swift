import SwiftUI
import AppKit

/// The material the island is made of, drawn behind its content. One view
/// per style so the island and the Settings previews share the exact look.
struct IslandSurface<S: Shape>: View {
    var style: IslandStyle
    var shape: S
    var accent: Color
    /// Closed and resting. Shadows drop away so the island sits flat in the
    /// menu bar, and on a notched screen it turns solid black so it reads
    /// as one piece with the camera housing.
    var resting: Bool
    var blendsWithNotch: Bool = false
    /// The Settings previews sit on a painted backdrop inside a window, so
    /// the pre-Tahoe blur there must sample the window, not the desktop.
    var withinWindow: Bool = false

    var body: some View {
        switch style {
        case .apple: apple
        case .glass: glass
        case .cartoon: cartoon
        }
    }

    // MARK: Apple

    /// Pure black with a hairline catching light along the edge, brightest
    /// at the top — the way the iPhone island picks up a glint.
    private var apple: some View {
        shape
            .fill(Color.black)
            .overlay {
                shape
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.5
                    )
                    .clipShape(shape)
                    .opacity(resting ? 0 : 1)
            }
            .shadow(color: .black.opacity(resting ? 0 : 0.5), radius: 20, y: 10)
    }

    // MARK: Glass

    private var glass: some View {
        ZStack {
            GlassBase(shape: shape, withinWindow: withinWindow)
            // Specular rim: light comes from the top left.
            shape
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .clipShape(shape)
            shape.fill(Color.black).opacity(resting && blendsWithNotch ? 1 : 0)
        }
        .shadow(color: .black.opacity(resting ? 0 : 0.28), radius: 24, y: 12)
    }

    // MARK: Cartoon

    /// Sticker look: an ink body with a little volume, a fat white outline,
    /// and a flat accent shadow with no blur at all, offset straight down.
    private var cartoon: some View {
        let ink = LinearGradient(
            colors: [Color(red: 0.17, green: 0.15, blue: 0.27), Color(red: 0.09, green: 0.08, blue: 0.15)],
            startPoint: .top, endPoint: .bottom
        )
        return ZStack {
            shape.fill(accent).offset(y: resting ? 2 : 6)
            shape.fill(ink)
            shape.stroke(Color.white, lineWidth: resting ? 3 : 5).clipShape(shape)
        }
        .overlay { shape.fill(Color.black).opacity(resting && blendsWithNotch ? 1 : 0) }
    }
}

/// Liquid Glass where the system has it, a frosted HUD blur everywhere else.
/// Both carry a dark tint: the content on top is white and has to stay
/// readable over a bright wallpaper.
private struct GlassBase<S: Shape>: View {
    var shape: S
    var withinWindow: Bool

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(.black.opacity(0.32)), in: shape)
        } else {
            VisualEffectBlur(blending: withinWindow ? .withinWindow : .behindWindow)
                .overlay(Color.black.opacity(0.28))
                .clipShape(shape)
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = blending
    }
}

/// Three small islands on a painted backdrop. Click one to wear it.
struct IslandStylePicker: View {
    @Binding var selection: IslandStyle
    var accent: Color

    var body: some View {
        HStack(spacing: 12) {
            ForEach(IslandStyle.allCases) { style in
                tile(style)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(_ style: IslandStyle) -> some View {
        let selected = selection == style
        let shape = NotchShape(top: 6, bottom: 16)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = style }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    // A wallpaper, so the glass has something to show through.
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.62, blue: 0.40), Color(red: 0.55, green: 0.40, blue: 0.95), Color(red: 0.25, green: 0.70, blue: 0.95)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Circle().fill(.white.opacity(0.5)).frame(width: 34).offset(x: -26, y: 22).blur(radius: 2)

                    ZStack(alignment: .top) {
                        IslandSurface(style: style, shape: shape, accent: accent, resting: false, withinWindow: true)
                        HStack(spacing: 5) {
                            Circle().fill(accent).frame(width: 8, height: 8)
                            Capsule().fill(.white.opacity(0.85)).frame(width: 34, height: 5)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .fontDesign(style == .cartoon ? .rounded : .default)
                    }
                    .frame(width: 96, height: 44)
                }
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? accent : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                }

                Text(style.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(style.title) style")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
