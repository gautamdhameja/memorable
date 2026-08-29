import SwiftUI

// Memorable V2 design system — quiet, photographic, and deliberately minimal.
enum Celestial {
    // MARK: - Colors

    enum Colors {
        // Backgrounds
        static let background = Color(red: 8 / 255, green: 11 / 255, blue: 18 / 255)       // #080B12
        static let surfaceDim = Color(red: 5 / 255, green: 7 / 255, blue: 14 / 255)         // #05070E
        static let surface = background
        static let surfaceContainerLowest = surfaceDim
        static let surfaceContainerLow = Color(red: 11 / 255, green: 16 / 255, blue: 26 / 255) // #0B101A
        static let surfaceContainer = Color(red: 15 / 255, green: 20 / 255, blue: 31 / 255) // #0F141F
        static let surfaceContainerHigh = Color(red: 21 / 255, green: 28 / 255, blue: 41 / 255) // #151C29
        static let surfaceContainerHighest = Color(red: 26 / 255, green: 35 / 255, blue: 50 / 255)
        static let surfaceVariant = surfaceContainerHigh
        static let surfaceBright = Color(red: 32 / 255, green: 42 / 255, blue: 58 / 255)

        // Primary
        static let primary = Color(red: 154 / 255, green: 198 / 255, blue: 1)       // #9AC6FF
        static let primaryDim = Color(red: 90 / 255, green: 160 / 255, blue: 1)     // #5AA0FF
        static let primaryContainer = primaryDim
        static let primaryFixedDim = primaryDim
        static let onPrimary = surfaceDim
        static let onPrimaryContainer = surfaceDim

        // Secondary
        static let secondary = Color(red: 220 / 255, green: 226 / 255, blue: 236 / 255) // #DCE2EC
        static let secondaryDim = Color(red: 151 / 255, green: 161 / 255, blue: 178 / 255)
        static let secondaryContainer = surfaceContainerHighest

        // Tertiary
        static let tertiary = primary
        static let tertiaryDim = primary

        // Text
        static let onSurface = Color(red: 244 / 255, green: 246 / 255, blue: 250 / 255) // #F4F6FA
        static let onSurfaceVariant = Color(red: 151 / 255, green: 161 / 255, blue: 178 / 255) // #97A1B2

        // Outlines
        static let outline = Color(red: 123 / 255, green: 133 / 255, blue: 152 / 255) // #7B8598
        static let outlineVariant = Color(red: 75 / 255, green: 85 / 255, blue: 102 / 255) // #4B5566

        // Error
        static let error = Color(red: 1, green: 98 / 255, blue: 89 / 255)            // #FF6259
        static let errorContainer = Color(red: 84 / 255, green: 24 / 255, blue: 27 / 255)

        // Accent highlights
        static let sky400_60 = primaryDim.opacity(0.6)
        static let sky200 = primary
        static let sky50 = onSurface

        // Warm accent (amber)
        static let amber = Color(red: 232 / 255, green: 168 / 255, blue: 94 / 255) // #E8A85E
        static let amberDim = Color(red: 201 / 255, green: 138 / 255, blue: 80 / 255)

        // Success / positive indicator
        static let emerald = Color(red: 84 / 255, green: 201 / 255, blue: 140 / 255)

        // Low-confidence indicator
        static let orange = amber

        static let hairline = Color.white.opacity(0.09)
    }

    // MARK: - Shared Geometry

    static let sharedCornerRadius: CGFloat = 12

    // MARK: - Gradients

    static let celestialBackground = LinearGradient(
        colors: [
            Colors.primaryDim.opacity(0.10),
            Colors.background
        ],
        startPoint: .top,
        endPoint: .center
    )

    static let memoryGradient = LinearGradient(
        colors: [
            Color(red: 44 / 255, green: 58 / 255, blue: 78 / 255),
            Color(red: 138 / 255, green: 101 / 255, blue: 68 / 255),
            Color(red: 216 / 255, green: 154 / 255, blue: 87 / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardOverlay = LinearGradient(
        colors: [.clear, Color.black.opacity(0.8)],
        startPoint: .center,
        endPoint: .bottom
    )

    // MARK: - Materials

    static let glassBackground = Colors.surfaceContainer.opacity(0.94)
    static let headerBackground = Colors.background.opacity(0.92)
    static let navBackground = Colors.background.opacity(0.94)
}

struct CelestialHairline: View {
    var body: some View {
        Rectangle()
            .fill(Celestial.Colors.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct FocusOrbit: View {
    var compact = false

    var body: some View {
        ZStack {
            Ellipse()
                .stroke(Celestial.Colors.primaryDim.opacity(0.18), lineWidth: 1)
            Circle()
                .fill(Celestial.Colors.amber)
                .frame(width: compact ? 4 : 6, height: compact ? 4 : 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }
}
