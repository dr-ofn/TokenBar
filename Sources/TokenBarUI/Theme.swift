import CoreGraphics
import LocalCore
import SwiftUI

/// A point size a font can take: never zero, negative or NaN, whatever the layout computed.
func points(_ size: Double) -> Double { size.isFinite ? max(1, size) : 1 }

public struct RGB: Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    init(hex: UInt32) {
        r = Double(hex >> 16 & 0xFF) / 255
        g = Double(hex >> 8 & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    /// `hue` in degrees, `saturation` and `lightness` in 0...1.
    init(hue: Double, saturation: Double, lightness: Double) {
        func channel(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            return lightness - a * max(-1, min(k - 3, min(9 - k, 1)))
        }
        r = channel(0)
        g = channel(8)
        b = channel(4)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    func cg(_ alpha: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

/// One colour per harness; models inside a harness are shades of it, and the token kinds
/// inside a model are lighter and darker strands of that shade.
public struct Palette: Sendable {
    public var isLight: Bool
    public var background: RGB
    public var text: RGB
    public var muted: RGB
    public var warning: RGB
    var saturation: Double
    var lightness: Double
    /// Ribbon opacity at the token end and the dollar end.
    var ribbonStart: Double
    var ribbonEnd: Double

    func ink(_ harness: HarnessID, tone: Int = 0, lift: Double = 0) -> RGB {
        RGB(hue: (harness.hue + Double(tone) * 7 + 360).truncatingRemainder(dividingBy: 360),
            saturation: saturation, lightness: lightness + Double(tone) * 0.06 + lift)
    }

    /// How a token kind shows inside a ribbon: its shift in lightness and how much it covers.
    func strand(_ kind: TokenKind) -> (lift: Double, alpha: Double) {
        switch kind {
        case .cacheRead: return (isLight ? 0.16 : -0.14, isLight ? 0.55 : 0.62)
        case .input: return (0, 0.82)
        case .cacheWrite: return (isLight ? -0.06 : 0.06, 0.92)
        case .output: return (isLight ? -0.14 : 0.14, 1)
        }
    }

    /// A token kind as a flat swatch, in a harness's colour or neutral.
    func strandColor(_ kind: TokenKind, harness: HarnessID?) -> Color {
        let look = strand(kind)
        guard let harness else { return muted.color.opacity(look.alpha) }
        return ink(harness, lift: look.lift).color.opacity(look.alpha)
    }

    public static let dark = Palette(
        isLight: false, background: RGB(hex: 0x0B0D10), text: RGB(hex: 0xE9ECF1), muted: RGB(hex: 0x9AA2AD),
        warning: RGB(hex: 0xFAB35C), saturation: 0.62, lightness: 0.6, ribbonStart: 0.6, ribbonEnd: 0.92)

    public static let light = Palette(
        isLight: true, background: RGB(hex: 0xEEF0F3), text: RGB(hex: 0x14171C), muted: RGB(hex: 0x525A66),
        warning: RGB(hex: 0x8A4300), saturation: 0.56, lightness: 0.46, ribbonStart: 0.62, ribbonEnd: 0.95)

    static func current(_ scheme: ColorScheme) -> Palette { scheme == .light ? light : dark }
}
