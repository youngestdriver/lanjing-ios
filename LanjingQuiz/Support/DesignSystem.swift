import SwiftUI

/// Duolingo palette, ported from apps/web/public/index.html CSS variables.
/// iOS 26+ 的主操作按钮改用系统 Liquid Glass(见 ActionButtonStyle),旧系统
/// 仍回退到原来的 3D 键帽外观。
enum DS {
    static let accent = Color(hex: 0x58cc02)
    static let accentHover = Color(hex: 0x61e002)
    static let accentActive = Color(hex: 0x58a700)
    static let orange = Color(hex: 0xff9600)
    static let blue = Color(hex: 0x1cb0f6)
    static let pink = Color(hex: 0xce82ff)
    static let red = Color(hex: 0xff4b4b)
    static let yellow = Color(hex: 0xffc800)
    static let gray = Color(hex: 0xafafaf)

    static let radiusSM: CGFloat = 12
    static let radiusMD: CGFloat = 16
    static let radiusLG: CGFloat = 20
    static let radiusPill: CGFloat = 9999
}

/// 主操作按钮。iOS 26+ 走系统 Liquid Glass:中性玻璃面 + 白字,按下由
/// `.interactive()` 提供玻璃的形变反馈;旧系统没有玻璃 API,回退到原来的
/// Duolingo 键帽(纯色填充 + 4pt 硬阴影),此时 `color` 继续承担绿/蓝/红的
/// 语义区分。玻璃分支不读 `color`——需求选定「中性玻璃 + 白字」,所有主
/// 按钮统一材质,主次只靠位置和文案。
struct ActionButtonStyle: ButtonStyle {
    var color: Color = DS.accent
    var radius: CGFloat = DS.radiusMD

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassBody(configuration)
        } else {
            keycapBody(configuration)
        }
#else
        // Xcode 16 / Swift 6.1 的 SDK 没有 iOS 26 的 glassEffect;直接回退
        // 键帽,保证旧工具链也能构建。
        keycapBody(configuration)
#endif
    }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    @ViewBuilder
    private func glassBody(_ configuration: Configuration) -> some View {
        configuration.label
            // 深色下就是白字;浅色下自动转深色——纯白压在浅色玻璃上
            // 对比度不足,系统 glass 按钮同样用自适应标签色。
            .foregroundStyle(.primary)
            .font(.system(size: 15, weight: .bold))
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius))
    }
#endif

    @ViewBuilder
    private func keycapBody(_ configuration: Configuration) -> some View {
        // 3D keycap:硬 4pt 底影,按下沉进阴影里。
        configuration.label
            .foregroundStyle(.white)
            .font(.system(size: 15, weight: .bold))
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: radius).fill(color))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(color.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: configuration.isPressed ? 0 : 4)
            .offset(y: configuration.isPressed ? 4 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct DisplayFontModifier: ViewModifier {
    var size: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .heavy, design: .rounded))
    }
}

extension View {
    func displayFont(_ size: CGFloat) -> some View {
        modifier(DisplayFontModifier(size: size))
    }
}
