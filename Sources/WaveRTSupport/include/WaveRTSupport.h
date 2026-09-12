//
//  WaveRTSupport.h
//  Lock-free state shared between Wave's control thread and the Core Audio
//  render thread.
//
//  Why this is C rather than Swift:
//
//  * The storage needs C11 `_Atomic`, and a C struct with `_Atomic` members
//    cannot be imported into Swift, so the type is kept opaque and reached
//    through the functions below.
//  * Swift's `Synchronization.Atomic` would do the job but is macOS 15+, and
//    Wave targets 14.2.
//  * Keeping it opaque also enforces the discipline that matters: the render
//    thread touches these cells once per buffer, never per sample, and never
//    touches anything else that could allocate, lock or log.
//
//  Every function here is wait-free. None allocates, blocks or calls into the
//  Swift runtime, which is what makes them safe inside an AudioDeviceIOProc.
//

#ifndef WAVE_RT_SUPPORT_H
#define WAVE_RT_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Compile-time ceiling on the channel count a render plan can describe.
/// Sized above any realistic interface so the channel map lives inline in the
/// render context rather than in storage the render thread has to chase.
#define WAVE_MAX_CHANNELS 64

/// Per-route control block. Opaque by design; see the file comment.
///
/// Declared as a typedef'd pointer to an incomplete struct — the same shape as
/// `sqlite3 *` — because that is the form Swift's C importer reliably maps to
/// `OpaquePointer`.
typedef struct WaveRTBlockStorage *WaveRTBlockRef;

/// Allocates a zeroed control block. Control thread only.
WaveRTBlockRef WaveRTBlockCreate(void);

/// Releases a control block. The caller must guarantee the render thread has
/// already been stopped; there is no reclamation scheme here on purpose,
/// because the engine's teardown order already provides one.
void WaveRTBlockDestroy(WaveRTBlockRef block);

// MARK: - Gain

/// Sets the gain the render thread should ramp towards. Control thread.
void WaveRTBlockSetTargetGain(WaveRTBlockRef block, float gain);

/// Reads the target gain. Render thread, once per buffer.
float WaveRTBlockTargetGain(WaveRTBlockRef block);

// MARK: - Activity gate

/// When false the render thread writes silence and skips its input entirely.
/// Used to park a route without tearing down Core Audio objects.
void WaveRTBlockSetActive(WaveRTBlockRef block, bool active);
bool WaveRTBlockIsActive(WaveRTBlockRef block);

// MARK: - Metering

/// Raises the stored peak if `value` is larger. Render thread, once per buffer
/// per channel.
void WaveRTBlockRaisePeak(WaveRTBlockRef block, int channel, float value);

/// Reads and clears the stored peak in one atomic step, so the UI can drain at
/// its own cadence without ever missing a transient. Control thread.
float WaveRTBlockDrainPeak(WaveRTBlockRef block, int channel);

/// Publishes the peak of the *tapped* signal, before gain and before mute.
///
/// Kept separate from the metered output peak on purpose. The silence watchdog
/// uses this to decide whether macOS is silently withholding capture
/// permission, and a muted fader legitimately produces a zero output peak — so
/// metering the output would make every muted app look like a permission
/// failure.
void WaveRTBlockRaiseInputPeak(WaveRTBlockRef block, float value);
float WaveRTBlockDrainInputPeak(WaveRTBlockRef block);

// MARK: - Counters

typedef enum {
    WaveRTCounterBuffers = 0,
    WaveRTCounterFrames,
    WaveRTCounterUnderruns,
    WaveRTCounterClampedSamples,
    WaveRTCounterSilentBuffers,
    WaveRTCounterFormatMismatches,
    WaveRTCounterCount
} WaveRTCounter;

/// Render thread, once per buffer.
void WaveRTBlockAddCounter(WaveRTBlockRef block, WaveRTCounter counter, uint64_t amount);

/// Control thread.
uint64_t WaveRTBlockCounter(WaveRTBlockRef block, WaveRTCounter counter);

#ifdef __cplusplus
}
#endif

#endif /* WAVE_RT_SUPPORT_H */
