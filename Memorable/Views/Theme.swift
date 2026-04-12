import SwiftUI

// Celestial Design System - derived from the design spec
enum Celestial {
    // MARK: - Colors

    enum Colors {
        // Backgrounds
        static let background = Color(red: 0.055, green: 0.082, blue: 0.118)       // #0e1520 (slightly lighter)
        static let surfaceDim = Color(red: 0.027, green: 0.059, blue: 0.090)        // #070f17
        static let surface = Color(red: 0.027, green: 0.059, blue: 0.090)           // #070f17
        static let surfaceContainerLowest = Color.black                               // #000000
        static let surfaceContainerLow = Color(red: 0.043, green: 0.078, blue: 0.114) // #0b141d
        static let surfaceContainer = Color(red: 0.067, green: 0.102, blue: 0.141)  // #111a24
        static let surfaceContainerHigh = Color(red: 0.086, green: 0.125, blue: 0.169) // #16202b
        static let surfaceContainerHighest = Color(red: 0.106, green: 0.153, blue: 0.196) // #1b2732
        static let surfaceVariant = Color(red: 0.106, green: 0.153, blue: 0.196)    // #1b2732
        static let surfaceBright = Color(red: 0.129, green: 0.176, blue: 0.227)     // #212d3a

        // Primary
        static let primary = Color(red: 0.435, green: 0.694, blue: 1.0)             // #6fb1ff
        static let primaryDim = Color(red: 0.263, green: 0.631, blue: 1.0)          // #43a1ff
        static let primaryContainer = Color(red: 0.298, green: 0.643, blue: 1.0)    // #4ca4ff
        static let primaryFixedDim = Color(red: 0.031, green: 0.592, blue: 1.0)     // #0897ff
        static let onPrimary = Color(red: 0.0, green: 0.188, blue: 0.341)           // #003057
        static let onPrimaryContainer = Color(red: 0.0, green: 0.141, blue: 0.263)  // #002443

        // Secondary
        static let secondary = Color(red: 0.702, green: 0.831, blue: 1.0)           // #b3d4ff
        static let secondaryDim = Color(red: 0.651, green: 0.776, blue: 0.941)      // #a6c6f0
        static let secondaryContainer = Color(red: 0.153, green: 0.286, blue: 0.424) // #27496c

        // Tertiary
        static let tertiary = Color(red: 0.706, green: 0.875, blue: 1.0)            // #b4dfff
        static let tertiaryDim = Color(red: 0.553, green: 0.773, blue: 0.922)       // #8dc5eb

        // Text
        static let onSurface = Color(red: 0.918, green: 0.945, blue: 0.992)         // #eaf1fd
        static let onSurfaceVariant = Color(red: 0.643, green: 0.675, blue: 0.718)  // #a4acb7

        // Outlines
        static let outline = Color(red: 0.431, green: 0.463, blue: 0.502)           // #6e7680
        static let outlineVariant = Color(red: 0.255, green: 0.286, blue: 0.322)    // #414952

        // Error
        static let error = Color(red: 1.0, green: 0.443, blue: 0.424)               // #ff716c
        static let errorContainer = Color(red: 0.624, green: 0.020, blue: 0.098)    // #9f0519

        // Accent highlights
        static let sky400_60 = Color(red: 0.22, green: 0.64, blue: 0.89).opacity(0.6)
        static let sky200 = Color(red: 0.73, green: 0.87, blue: 0.98)
        static let sky50 = Color(red: 0.94, green: 0.97, blue: 1.0)

        // Warm accent (amber)
        static let amber = Color(red: 1.0, green: 0.718, blue: 0.302)           // #FFB74D
        static let amberDim = Color(red: 0.90, green: 0.62, blue: 0.20)          // dimmer for subtle use

        // Success / positive indicator
        static let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)       // #34D399

        // Low-confidence indicator
        static let orange = Color(red: 1.0, green: 0.584, blue: 0.224)          // #FF9539
    }

    // MARK: - Gradients

    static let celestialBackground = LinearGradient(
        colors: [
            Color(red: 0.031, green: 0.592, blue: 1.0).opacity(0.15),
            Colors.background
        ],
        startPoint: .top,
        endPoint: .center
    )

    static let cardOverlay = LinearGradient(
        colors: [.clear, Color.black.opacity(0.8)],
        startPoint: .center,
        endPoint: .bottom
    )

    // MARK: - Materials

    static let glassBackground = Colors.surfaceContainerLowest.opacity(0.4)
    static let headerBackground = Color(red: 0.04, green: 0.20, blue: 0.36).opacity(0.6)
    static let navBackground = Color(red: 0.02, green: 0.10, blue: 0.20).opacity(0.6)
}
