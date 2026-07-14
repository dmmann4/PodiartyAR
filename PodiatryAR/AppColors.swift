//
//  AppColors.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/14/26.
//

import SwiftUI

extension Color {

    // MARK: - Brand Colors (sampled from logo)

    /// Light teal — highlight face of the cross icon
    static let brandTealLight = Color(red: 154/255, green: 214/255, blue: 215/255) // #9AD6D7

    /// Deep teal — primary brand color, used for the shadowed arms of the cross
    static let brandTeal = Color(red: 71/255, green: 151/255, blue: 160/255) // #4797A0

    /// Lime accent — the "A" chevron shape in the mark
    static let brandLime = Color(red: 197/255, green: 222/255, blue: 42/255) // #C5DE2A

    /// Ink — near-black used for the wordmark
    static let brandInk = Color(red: 5/255, green: 7/255, blue: 13/255) // #05070D

    /// Secondary gray — subtitle text ("3D Medical Printing")
    static let brandSecondary = Color(red: 107/255, green: 114/255, blue: 128/255) // #6B7280

    // MARK: - UI Surface Colors (derived, cleaned up for app use)

    /// Clean app background — lighter than the photographed mockup gray so UI stays crisp
    static let appBackground = Color(red: 247/255, green: 248/255, blue: 249/255) // #F7F8F9

    /// Card / surface background
    static let appSurface = Color.white

    /// Subtle divider / stroke color
    static let appDivider = Color(red: 228/255, green: 230/255, blue: 232/255) // #E4E6E8

    // MARK: - Gradients

    static let brandTealGradient = LinearGradient(
        colors: [.brandTealLight, .brandTeal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let brandAccentGradient = LinearGradient(
        colors: [.brandTeal, .brandLime],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Soft radial backdrop used behind the splash logo, echoing the photographed vignette
    static let splashBackdrop = RadialGradient(
        colors: [Color(red: 226/255, green: 229/255, blue: 231/255), Color(red: 244/255, green: 245/255, blue: 246/255)],
        center: .center,
        startRadius: 20,
        endRadius: 420
    )
}


//
//  AppFonts.swift
//  The 3D Formula
//
//  Typography matching the geometric-rounded wordmark in the logo.
//
//  RECOMMENDED FONT: "Poppins" (free, Google Fonts)
//  https://fonts.google.com/specimen/Poppins
//  It's the closest free match to the logo's geometric sans: thick even
//  strokes, circular "o", single-story "a". Century Gothic (paid, included
//  on macOS) is an even closer visual match if you have a license.
//
//  SETUP (to use Poppins):
//  1. Download the .ttf files from fonts.google.com/specimen/Poppins
//     (grab at least Regular, Medium, SemiBold, Bold, ExtraBold)
//  2. Drag them into your Xcode project (check "Copy items if needed")
//  3. Add them to Info.plist under "Fonts provided by application"
//     (UIAppFonts), e.g.:
//       <key>UIAppFonts</key>
//       <array>
//         <string>Poppins-Regular.ttf</string>
//         <string>Poppins-Medium.ttf</string>
//         <string>Poppins-SemiBold.ttf</string>
//         <string>Poppins-Bold.ttf</string>
//         <string>Poppins-ExtraBold.ttf</string>
//       </array>
//  4. Set `useCustomFont = true` below once the files are added.
//
//  Until then, this file automatically falls back to San Francisco's
//  Rounded design, which is a very reasonable built-in stand-in —
//  no setup required.
//

import SwiftUI

enum AppFont {

    /// Flip to true after adding Poppins .ttf files to the project + Info.plist
    static let useCustomFont = false

    private static func poppins(_ size: CGFloat, weight: Font.Weight) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Poppins-Bold"
        case .semibold:             name = "Poppins-SemiBold"
        case .medium:                name = "Poppins-Medium"
        default:                     name = "Poppins-Regular"
        }
        return Font.custom(name, size: size)
    }

    private static func rounded(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        useCustomFont ? poppins(size, weight: weight) : rounded(size, weight: weight)
    }

    // MARK: - Semantic text styles

    static var splashTitle: Font { font(38, weight: .heavy) }
    static var splashSubtitle: Font { font(16, weight: .medium) }

    static var largeTitle: Font { font(32, weight: .bold) }
    static var title: Font { font(22, weight: .bold) }
    static var headline: Font { font(17, weight: .semibold) }
    static var body: Font { font(15, weight: .regular) }
    static var caption: Font { font(13, weight: .medium) }
    static var button: Font { font(16, weight: .semibold) }
}
