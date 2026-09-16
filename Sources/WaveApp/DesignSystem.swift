import SwiftUI
import AppKit

/// Wave's visual vocabulary.
///
/// The target is a control surface, not a dashboard: a graphite and slate
/// ground, one cool signal colour, and hierarchy carried by spacing, alignment
/// and meter activity rather than by cards, borders or headings. Everything
/// here is defined once so a row cannot quietly drift out of alignment with the
/// row above it.
enum Wave {

    // MARK: - Palette

    /// Electric cobalt. The only saturated colour in the app, reserved for
    /// live signal: meter fill, the active part of a fader, focus rings.
    /// Restricting it to one meaning is what lets a glance at the popover
    /// answer "what is making noise".
    static let signal = Color(nsColor: NSColor(name: "waveSignal") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.36, green: 0.58, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.36, blue: 0.92, alpha: 1)
    })

    /// Used only where a level has actually reached full scale.
    static let overload = Color(nsColor: NSColor(name: "waveOverload") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.66, blue: 0.31, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.42, blue: 0.05, alpha: 1)
    })

    /// The unlit part of a meter. Dark enough to read as "off" without becoming
    /// a border.
    static let meterBed = Color(nsColor: NSColor(name: "waveMeterBed") { appearance in
        let boost = appearance.isHighContrast ? 0.16 : 0.0
        return appearance.isDark
            ? NSColor(white: 1.0, alpha: 0.10 + boost)
            : NSColor(white: 0.0, alpha: 0.11 + boost)
    })

    /// Ground for the popover behind the system material.
    static let surface = Color(nsColor: NSColor(name: "waveSurface") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
    })

    /// Very low-contrast fill used to mark the row under the pointer. Never a
    /// card: no border, no shadow, no corner beyond the row's own.
    static let rowHighlight = Color(nsColor: NSColor(name: "waveRowHighlight") { appearance in
        appearance.isDark
            ? NSColor(white: 1.0, alpha: 0.055)
            : NSColor(white: 0.0, alpha: 0.045)
    })

    static let hairline = Color(nsColor: NSColor(name: "waveHairline") { appearance in
        let boost = appearance.isHighContrast ? 0.22 : 0.0
        return appearance.isDark
            ? NSColor(white: 1.0, alpha: 0.08 + boost)
            : NSColor(white: 0.0, alpha: 0.09 + boost)
    })

    // MARK: - Metrics

    enum Metrics {
        /// The popover reads best around here: wide enough for a name, a meter
        /// and a fader on two lines without either wrapping or floating.
        static let popoverWidth: CGFloat = 420
        static let maxPopoverHeight: CGFloat = 660

        static let horizontalPadding: CGFloat = 14
        /// Tight on purpose. Every point here is multiplied by the number of
        /// rows, and the popover's job is to show them all at once.
        static let rowVerticalPadding: CGFloat = 6
        static let rowCornerRadius: CGFloat = 6

        static let iconSize: CGFloat = 24
        /// Gap between the icon and the name. Icon + gap is also the indent for
        /// the second line, which is what makes the two lines of a strip read
        /// as one block.
        static let iconGap: CGFloat = 10
        static var contentIndent: CGFloat { iconSize + iconGap }

        static let meterWidth: CGFloat = 78
        static let meterBarHeight: CGFloat = 3
        static let meterBarGap: CGFloat = 2
        static let meterSegments = 26

        static let controlHeight: CGFloat = 20
        static let percentWidth: CGFloat = 36
        static let sectionSpacing: CGFloat = 8
    }

    // MARK: - Type

    enum Type_ {
        /// App names. The one place with any weight, because it is the thing
        /// people scan.
        static let name = Font.system(size: 13, weight: .medium)
        static let secondary = Font.system(size: 11, weight: .regular)
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// Monospaced digits so a changing percentage does not shift the layout.
        static let readout = Font.system(size: 11, weight: .regular).monospacedDigit()
    }
}

extension NSAppearance {
    /// Matches against the accessibility variants too, so Increase Contrast
    /// does not fall through to the light palette while the system is dark.
    var isDark: Bool {
        let match = bestMatch(from: [.aqua, .darkAqua,
                                     .accessibilityHighContrastAqua,
                                     .accessibilityHighContrastDarkAqua])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }

    var isHighContrast: Bool {
        let match = bestMatch(from: [.aqua, .darkAqua,
                                     .accessibilityHighContrastAqua,
                                     .accessibilityHighContrastDarkAqua])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }
}

/// A one-pixel rule used between sections. Explicitly not a card edge.
struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Wave.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Small, quiet section label. Sentence case, like everything else in Wave.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Wave.Type_.sectionHeader)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Wave.Type_.secondary)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Wave.Metrics.horizontalPadding)
        .padding(.top, Wave.Metrics.sectionSpacing)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}
