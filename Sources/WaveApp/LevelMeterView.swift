import SwiftUI
import WaveCore

/// The stereo level meter.
///
/// Reduce Motion is honoured upstream, in `MixerViewModel`, by dropping the
/// meter's update rate from 30 Hz to 4 Hz; the canvas itself never animates
/// implicitly, so there is nothing to disable here.
///
/// This is Wave's main piece of visual identity, so it is drawn rather than
/// assembled from stacked views: a `Canvas` redrawing 26 segments twice per row
/// at 30 Hz costs almost nothing, whereas 52 animated `Rectangle`s per row does
/// not.
///
/// Two thin bars, left above right, on a common bed. A peak-hold marker rides
/// the high-water mark so a transient is still visible one frame later. The
/// only colour is the signal cobalt, until a level actually reaches full scale,
/// which is the one case worth a different hue.
struct LevelMeterView: View {

    var meter: StereoMeter
    var isEnabled: Bool = true
    /// Rendered instead of a live level when Wave is not intercepting this app.
    var placeholder: Bool = false

    @Environment(\.colorSchemeContrast) private var contrast

    private var barHeight: CGFloat { Wave.Metrics.meterBarHeight }
    private var gap: CGFloat { Wave.Metrics.meterBarGap }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(&context, size: size, level: meter.left.displayLevel,
                 peak: meter.left.peakLevel, y: 0)
            draw(&context, size: size, level: meter.right.displayLevel,
                 peak: meter.right.peakLevel, y: barHeight + gap)
        }
        .frame(width: Wave.Metrics.meterWidth, height: barHeight * 2 + gap)
        .accessibilityElement()
        .accessibilityLabel("Output level")
        .accessibilityValue(accessibilityValue)
        // The meter is decorative detail for a screen-reader user until it says
        // something: a single summary value beats 52 announcing segments.
        .accessibilityHidden(placeholder)
    }

    private func draw(_ context: inout GraphicsContext,
                      size: CGSize,
                      level: Float,
                      peak: Float,
                      y: CGFloat) {
        let segments = Wave.Metrics.meterSegments
        let spacing: CGFloat = 1
        let segmentWidth = (size.width - CGFloat(segments - 1) * spacing) / CGFloat(segments)
        guard segmentWidth > 0 else { return }

        let lit = placeholder || !isEnabled ? 0 : Int((Float(segments) * level).rounded())
        let peakIndex = placeholder || !isEnabled ? -1 : Int((Float(segments) * peak).rounded()) - 1

        // Full scale is the last segment; only then does the meter change hue.
        let isOverloading = lit >= segments

        for index in 0..<segments {
            let x = CGFloat(index) * (segmentWidth + spacing)
            let rect = CGRect(x: x, y: y, width: segmentWidth, height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: barHeight / 2)

            if index < lit {
                let isTop = index == segments - 1
                context.fill(path, with: .color(isTop && isOverloading ? Wave.overload : Wave.signal))
            } else if index == peakIndex {
                context.fill(path, with: .color(Wave.signal.opacity(contrast == .increased ? 0.85 : 0.55)))
            } else {
                context.fill(path, with: .color(Wave.meterBed))
            }
        }
    }

    private var accessibilityValue: String {
        guard !placeholder, isEnabled else { return "Not routed" }
        let left = Int(meter.left.displayLevel * 100)
        let right = Int(meter.right.displayLevel * 100)
        if left == 0 && right == 0 { return "Silent" }
        return "Left \(left) percent, right \(right) percent"
    }
}
