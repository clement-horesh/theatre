import AVFoundation
import CoreMedia
import Foundation

struct SubtitleAppearance: Codable, Equatable {
    enum Position: String, Codable, CaseIterable {
        case bottom = "Bottom"
        case raised = "Raised"
        case higher = "Higher"
    }
    enum Size: String, Codable, CaseIterable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
        case extraLarge = "Extra Large"
        var relativeSize: Int {
            switch self {
            case .small: 28
            case .medium: 22
            case .large: 16
            case .extraLarge: 12
            }
        }
    }
    enum TextColor: String, Codable, CaseIterable {
        case white = "White"
        case yellow = "Yellow"
        case gray = "Light Gray"
        case cyan = "Cyan"
        var rgb: Int {
            switch self {
            case .white: 0xFFFFFF
            case .yellow: 0xFFFF00
            case .gray: 0xD3D3D3
            case .cyan: 0x00FFFF
            }
        }
    }
    var position: Position = .bottom
    var size: Size = .medium
    var color: TextColor = .white
    var background = false
    static let standard = SubtitleAppearance()
    static let defaultsKey = "subtitleAppearance"

    var vlcOptions: [String] {
        if self == .standard { return [] }
        let margin: Int
        switch position {
        case .bottom: margin = 0
        case .raised: margin = 60
        case .higher: margin = 120
        }
        return [
            "--freetype-rel-fontsize=\(size.relativeSize)", "--freetype-color=\(color.rgb)",
            "--sub-margin=\(margin)", "--freetype-background-opacity=\(background ? 180 : 0)",
        ]
    }

    var nativeStyle: AVTextStyleRule? {
        if self == .standard { return nil }
        let rgb = color.rgb
        let components: [Double] = [
            1, Double((rgb >> 16) & 255) / 255,
            Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255,
        ]
        let line: Double
        switch position {
        case .bottom: line = 95
        case .raised: line = 85
        case .higher: line = 75
        }
        return AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_RelativeFontSize as String: 2200 / Double(size.relativeSize),
            kCMTextMarkupAttribute_ForegroundColorARGB as String: components,
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [background ? 0.7 : 0, 0, 0, 0],
            kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String: line,
        ])
    }
}
