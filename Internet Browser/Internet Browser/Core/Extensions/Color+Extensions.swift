//
//  Color+Extensions.swift
//  Internet Browser
//

import SwiftUI

extension Color {
    /// Parses a CSS color string as found in Firefox theme manifests:
    /// `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa`, `rgb()`/`rgba()`, `hsl()`/`hsla()`,
    /// and named colors. `"transparent"` parses to a fully clear color.
    /// Returns nil for anything unparseable.
    init?(css: String) {
        guard let rgba = CSSColor.parse(css) else { return nil }
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// Parser for the CSS color syntaxes Firefox accepts in `theme.colors`.
/// Kept as plain-Double RGBA so it has no SwiftUI dependency and can be
/// exercised standalone.
enum CSSColor {
    struct RGBA: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    static func parse(_ string: String) -> RGBA? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("#") {
            return parseHex(String(value.dropFirst()))
        }
        if value.hasPrefix("rgb") {
            return parseFunction(value, expectingHue: false)
        }
        if value.hasPrefix("hsl") {
            return parseFunction(value, expectingHue: true)
        }
        return namedColors[value]
    }

    // MARK: - Hex

    /// CSS hex order: #rgb, #rgba, #rrggbb, #rrggbbaa (alpha LAST — unlike
    /// the ARGB order `Color(hex:)` above uses for its 8-digit form).
    private static func parseHex(_ hex: String) -> RGBA? {
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        func nibble(_ offset: Int) -> Double {
            let char = hex[hex.index(hex.startIndex, offsetBy: offset)]
            return Double(char.hexDigitValue ?? 0)
        }
        func byte(_ offset: Int) -> Double {
            nibble(offset) * 16 + nibble(offset + 1)
        }

        switch hex.count {
        case 3:
            return RGBA(red: nibble(0) * 17 / 255, green: nibble(1) * 17 / 255, blue: nibble(2) * 17 / 255, alpha: 1)
        case 4:
            return RGBA(red: nibble(0) * 17 / 255, green: nibble(1) * 17 / 255, blue: nibble(2) * 17 / 255, alpha: nibble(3) * 17 / 255)
        case 6:
            return RGBA(red: byte(0) / 255, green: byte(2) / 255, blue: byte(4) / 255, alpha: 1)
        case 8:
            return RGBA(red: byte(0) / 255, green: byte(2) / 255, blue: byte(4) / 255, alpha: byte(6) / 255)
        default:
            return nil
        }
    }

    // MARK: - rgb()/rgba()/hsl()/hsla()

    private static func parseFunction(_ value: String, expectingHue: Bool) -> RGBA? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = String(value[value.startIndex..<open])
        guard name == (expectingHue ? "hsl" : "rgb") || name == (expectingHue ? "hsla" : "rgba") else { return nil }

        let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
        // Accept both legacy commas and the modern space syntax with "/" for alpha.
        let parts = inner
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        let alpha = parts.count == 4 ? parseAlpha(parts[3]) : 1
        guard let alpha else { return nil }

        if expectingHue {
            guard let hue = parseHue(parts[0]),
                  let saturation = parsePercent(parts[1]),
                  let lightness = parsePercent(parts[2]) else { return nil }
            let rgb = hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
            return RGBA(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
        } else {
            guard let red = parseChannel(parts[0]),
                  let green = parseChannel(parts[1]),
                  let blue = parseChannel(parts[2]) else { return nil }
            return RGBA(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// An rgb() channel: 0–255 number or percentage, clamped to 0...1.
    private static func parseChannel(_ part: String) -> Double? {
        if part.hasSuffix("%") {
            return parsePercent(part)
        }
        guard let number = Double(part) else { return nil }
        return min(max(number / 255, 0), 1)
    }

    /// A percentage token ("86%") to 0...1. hsl() requires the "%".
    private static func parsePercent(_ part: String) -> Double? {
        guard part.hasSuffix("%"), let number = Double(part.dropLast()) else { return nil }
        return min(max(number / 100, 0), 1)
    }

    /// Alpha: 0–1 number or percentage.
    private static func parseAlpha(_ part: String) -> Double? {
        if part.hasSuffix("%") {
            return parsePercent(part)
        }
        guard let number = Double(part) else { return nil }
        return min(max(number, 0), 1)
    }

    /// Hue in degrees (bare number or "deg" suffix), any value wrapped into 0..<360.
    private static func parseHue(_ part: String) -> Double? {
        let token = part.hasSuffix("deg") ? String(part.dropLast(3)) : part
        guard let number = Double(token) else { return nil }
        let wrapped = number.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePrime = hue / 60
        let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2

        let (r, g, b): (Double, Double, Double)
        switch huePrime {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default:   (r, g, b) = (chroma, 0, x)
        }
        return (r + match, g + match, b + match)
    }

    // MARK: - Named colors

    /// The CSS named colors (full CSS Color Module level 4 / X11 set), plus
    /// `transparent`. Values are 0–255 RGB triples; alpha 1 except transparent.
    private static let namedColors: [String: RGBA] = {
        let table: [String: (Int, Int, Int)] = [
            "aliceblue": (240, 248, 255), "antiquewhite": (250, 235, 215), "aqua": (0, 255, 255),
            "aquamarine": (127, 255, 212), "azure": (240, 255, 255), "beige": (245, 245, 220),
            "bisque": (255, 228, 196), "black": (0, 0, 0), "blanchedalmond": (255, 235, 205),
            "blue": (0, 0, 255), "blueviolet": (138, 43, 226), "brown": (165, 42, 42),
            "burlywood": (222, 184, 135), "cadetblue": (95, 158, 160), "chartreuse": (127, 255, 0),
            "chocolate": (210, 105, 30), "coral": (255, 127, 80), "cornflowerblue": (100, 149, 237),
            "cornsilk": (255, 248, 220), "crimson": (220, 20, 60), "cyan": (0, 255, 255),
            "darkblue": (0, 0, 139), "darkcyan": (0, 139, 139), "darkgoldenrod": (184, 134, 11),
            "darkgray": (169, 169, 169), "darkgreen": (0, 100, 0), "darkgrey": (169, 169, 169),
            "darkkhaki": (189, 183, 107), "darkmagenta": (139, 0, 139), "darkolivegreen": (85, 107, 47),
            "darkorange": (255, 140, 0), "darkorchid": (153, 50, 204), "darkred": (139, 0, 0),
            "darksalmon": (233, 150, 122), "darkseagreen": (143, 188, 143), "darkslateblue": (72, 61, 139),
            "darkslategray": (47, 79, 79), "darkslategrey": (47, 79, 79), "darkturquoise": (0, 206, 209),
            "darkviolet": (148, 0, 211), "deeppink": (255, 20, 147), "deepskyblue": (0, 191, 255),
            "dimgray": (105, 105, 105), "dimgrey": (105, 105, 105), "dodgerblue": (30, 144, 255),
            "firebrick": (178, 34, 34), "floralwhite": (255, 250, 240), "forestgreen": (34, 139, 34),
            "fuchsia": (255, 0, 255), "gainsboro": (220, 220, 220), "ghostwhite": (248, 248, 255),
            "gold": (255, 215, 0), "goldenrod": (218, 165, 32), "gray": (128, 128, 128),
            "green": (0, 128, 0), "greenyellow": (173, 255, 47), "grey": (128, 128, 128),
            "honeydew": (240, 255, 240), "hotpink": (255, 105, 180), "indianred": (205, 92, 92),
            "indigo": (75, 0, 130), "ivory": (255, 255, 240), "khaki": (240, 230, 140),
            "lavender": (230, 230, 250), "lavenderblush": (255, 240, 245), "lawngreen": (124, 252, 0),
            "lemonchiffon": (255, 250, 205), "lightblue": (173, 216, 230), "lightcoral": (240, 128, 128),
            "lightcyan": (224, 255, 255), "lightgoldenrodyellow": (250, 250, 210), "lightgray": (211, 211, 211),
            "lightgreen": (144, 238, 144), "lightgrey": (211, 211, 211), "lightpink": (255, 182, 193),
            "lightsalmon": (255, 160, 122), "lightseagreen": (32, 178, 170), "lightskyblue": (135, 206, 250),
            "lightslategray": (119, 136, 153), "lightslategrey": (119, 136, 153), "lightsteelblue": (176, 196, 222),
            "lightyellow": (255, 255, 224), "lime": (0, 255, 0), "limegreen": (50, 205, 50),
            "linen": (250, 240, 230), "magenta": (255, 0, 255), "maroon": (128, 0, 0),
            "mediumaquamarine": (102, 205, 170), "mediumblue": (0, 0, 205), "mediumorchid": (186, 85, 211),
            "mediumpurple": (147, 112, 219), "mediumseagreen": (60, 179, 113), "mediumslateblue": (123, 104, 238),
            "mediumspringgreen": (0, 250, 154), "mediumturquoise": (72, 209, 204), "mediumvioletred": (199, 21, 133),
            "midnightblue": (25, 25, 112), "mintcream": (245, 255, 250), "mistyrose": (255, 228, 225),
            "moccasin": (255, 228, 181), "navajowhite": (255, 222, 173), "navy": (0, 0, 128),
            "oldlace": (253, 245, 230), "olive": (128, 128, 0), "olivedrab": (107, 142, 35),
            "orange": (255, 165, 0), "orangered": (255, 69, 0), "orchid": (218, 112, 214),
            "palegoldenrod": (238, 232, 170), "palegreen": (152, 251, 152), "paleturquoise": (175, 238, 238),
            "palevioletred": (219, 112, 147), "papayawhip": (255, 239, 213), "peachpuff": (255, 218, 185),
            "peru": (205, 133, 63), "pink": (255, 192, 203), "plum": (221, 160, 221),
            "powderblue": (176, 224, 230), "purple": (128, 0, 128), "rebeccapurple": (102, 51, 153),
            "red": (255, 0, 0), "rosybrown": (188, 143, 143), "royalblue": (65, 105, 225),
            "saddlebrown": (139, 69, 19), "salmon": (250, 128, 114), "sandybrown": (244, 164, 96),
            "seagreen": (46, 139, 87), "seashell": (255, 245, 238), "sienna": (160, 82, 45),
            "silver": (192, 192, 192), "skyblue": (135, 206, 235), "slateblue": (106, 90, 205),
            "slategray": (112, 128, 144), "slategrey": (112, 128, 144), "snow": (255, 250, 250),
            "springgreen": (0, 255, 127), "steelblue": (70, 130, 180), "tan": (210, 180, 140),
            "teal": (0, 128, 128), "thistle": (216, 191, 216), "tomato": (255, 99, 71),
            "turquoise": (64, 224, 208), "violet": (238, 130, 238), "wheat": (245, 222, 179),
            "white": (255, 255, 255), "whitesmoke": (245, 245, 245), "yellow": (255, 255, 0),
            "yellowgreen": (154, 205, 50),
        ]
        var colors = table.mapValues { RGBA(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255, alpha: 1) }
        colors["transparent"] = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        return colors
    }()
}
