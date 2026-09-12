import Foundation
import WaveRTSupport

/// Swift face of the lock-free control block the render thread reads.
///
/// This is the only channel between Wave's UI and its audio callback. Moving a
/// fader stores one float; the callback loads that float once per buffer.
/// There is no queue, no lock, no notification and nothing to allocate, which
/// is what keeps the render thread free of the things that cause dropouts.
///
/// Lifetime is manual because the render thread holds a raw pointer to the
/// same storage: ``dispose()`` must only be called after the IO proc has been
/// stopped and destroyed. ``AudioRoutingEngine`` owns that ordering.
public final class RealtimeControlBlock: @unchecked Sendable {

    /// Raw pointer handed to the IO callback. Reading through it involves no
    /// Swift object, so the callback never touches ARC.
    public let pointer: OpaquePointer

    private var disposed = false

    public init?() {
        guard let raw = WaveRTBlockCreate() else { return nil }
        self.pointer = raw
    }

    deinit {
        dispose()
    }

    /// Frees the block. Safe to call more than once; unsafe to call while an
    /// IO proc is still running against it.
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        WaveRTBlockDestroy(pointer)
    }

    // MARK: - Control thread writes

    /// The linear gain the render thread ramps towards.
    public var targetGain: Float {
        get { WaveRTBlockTargetGain(pointer) }
        set { WaveRTBlockSetTargetGain(pointer, newValue) }
    }

    /// When false the callback emits silence and does not read its input.
    public var isActive: Bool {
        get { WaveRTBlockIsActive(pointer) }
        set { WaveRTBlockSetActive(pointer, newValue) }
    }

    // MARK: - Control thread reads

    /// Reads and clears both channel peaks.
    public func drainPeaks() -> (left: Float, right: Float) {
        let raw = pointer
        return (WaveRTBlockDrainPeak(raw, 0), WaveRTBlockDrainPeak(raw, 1))
    }

    /// Reads and clears the pre-gain peak used by the silence watchdog.
    public func drainInputPeak() -> Float {
        WaveRTBlockDrainInputPeak(pointer)
    }

    public func statistics() -> RenderStatisticsSnapshot {
        let raw = pointer
        var snapshot = RenderStatisticsSnapshot()
        snapshot.buffersRendered = WaveRTBlockCounter(raw, WaveRTCounterBuffers)
        snapshot.framesRendered = WaveRTBlockCounter(raw, WaveRTCounterFrames)
        snapshot.underruns = WaveRTBlockCounter(raw, WaveRTCounterUnderruns)
        snapshot.clampedSamples = WaveRTBlockCounter(raw, WaveRTCounterClampedSamples)
        snapshot.silentBuffers = WaveRTBlockCounter(raw, WaveRTCounterSilentBuffers)
        snapshot.formatMismatches = WaveRTBlockCounter(raw, WaveRTCounterFormatMismatches)
        return snapshot
    }
}
