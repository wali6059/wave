#include "WaveRTSupport.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/// Only the first two channels are metered. Wave's taps are stereo mixdowns
/// and the UI shows a stereo pair, so metering wider layouts would cost render
/// time for something nothing displays.
#define WAVE_METERED_CHANNELS 2

struct WaveRTBlockStorage {
    _Atomic uint32_t targetGainBits;
    _Atomic bool active;
    _Atomic uint32_t peakBits[WAVE_METERED_CHANNELS];
    _Atomic uint32_t inputPeakBits;
    _Atomic uint64_t counters[WaveRTCounterCount];
};

static inline uint32_t wave_bits_from_float(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float wave_float_from_bits(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

WaveRTBlockRef WaveRTBlockCreate(void) {
    WaveRTBlockRef block = (WaveRTBlockRef)calloc(1, sizeof(struct WaveRTBlockStorage));
    if (block == NULL) { return NULL; }

    atomic_init(&block->targetGainBits, wave_bits_from_float(0.0f));
    atomic_init(&block->active, false);
    for (int i = 0; i < WAVE_METERED_CHANNELS; i++) {
        atomic_init(&block->peakBits[i], wave_bits_from_float(0.0f));
    }
    atomic_init(&block->inputPeakBits, wave_bits_from_float(0.0f));
    for (int i = 0; i < (int)WaveRTCounterCount; i++) {
        atomic_init(&block->counters[i], 0);
    }
    return block;
}

void WaveRTBlockDestroy(WaveRTBlockRef block) {
    free(block);
}

void WaveRTBlockSetTargetGain(WaveRTBlockRef block, float gain) {
    if (block == NULL) { return; }
    if (gain < 0.0f) { gain = 0.0f; }
    if (gain > 1.0f) { gain = 1.0f; }
    atomic_store_explicit(&block->targetGainBits, wave_bits_from_float(gain), memory_order_relaxed);
}

float WaveRTBlockTargetGain(WaveRTBlockRef block) {
    if (block == NULL) { return 0.0f; }
    return wave_float_from_bits(atomic_load_explicit(&block->targetGainBits, memory_order_relaxed));
}

void WaveRTBlockSetActive(WaveRTBlockRef block, bool active) {
    if (block == NULL) { return; }
    atomic_store_explicit(&block->active, active, memory_order_relaxed);
}

bool WaveRTBlockIsActive(WaveRTBlockRef block) {
    if (block == NULL) { return false; }
    return atomic_load_explicit(&block->active, memory_order_relaxed);
}

void WaveRTBlockRaisePeak(WaveRTBlockRef block, int channel, float value) {
    if (block == NULL) { return; }
    if (channel < 0 || channel >= WAVE_METERED_CHANNELS) { return; }

    uint32_t desired = wave_bits_from_float(value);
    uint32_t expected = atomic_load_explicit(&block->peakBits[channel], memory_order_relaxed);
    for (;;) {
        if (!(value > wave_float_from_bits(expected))) { return; }
        if (atomic_compare_exchange_weak_explicit(&block->peakBits[channel],
                                                  &expected,
                                                  desired,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
            return;
        }
    }
}

float WaveRTBlockDrainPeak(WaveRTBlockRef block, int channel) {
    if (block == NULL) { return 0.0f; }
    if (channel < 0 || channel >= WAVE_METERED_CHANNELS) { return 0.0f; }
    uint32_t bits = atomic_exchange_explicit(&block->peakBits[channel],
                                             wave_bits_from_float(0.0f),
                                             memory_order_relaxed);
    return wave_float_from_bits(bits);
}

void WaveRTBlockRaiseInputPeak(WaveRTBlockRef block, float value) {
    if (block == NULL) { return; }
    uint32_t desired = wave_bits_from_float(value);
    uint32_t expected = atomic_load_explicit(&block->inputPeakBits, memory_order_relaxed);
    for (;;) {
        if (!(value > wave_float_from_bits(expected))) { return; }
        if (atomic_compare_exchange_weak_explicit(&block->inputPeakBits,
                                                  &expected,
                                                  desired,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
            return;
        }
    }
}

float WaveRTBlockDrainInputPeak(WaveRTBlockRef block) {
    if (block == NULL) { return 0.0f; }
    uint32_t bits = atomic_exchange_explicit(&block->inputPeakBits,
                                             wave_bits_from_float(0.0f),
                                             memory_order_relaxed);
    return wave_float_from_bits(bits);
}

void WaveRTBlockAddCounter(WaveRTBlockRef block, WaveRTCounter counter, uint64_t amount) {
    if (block == NULL) { return; }
    if ((int)counter < 0 || (int)counter >= (int)WaveRTCounterCount) { return; }
    atomic_fetch_add_explicit(&block->counters[counter], amount, memory_order_relaxed);
}

uint64_t WaveRTBlockCounter(WaveRTBlockRef block, WaveRTCounter counter) {
    if (block == NULL) { return 0; }
    if ((int)counter < 0 || (int)counter >= (int)WaveRTCounterCount) { return 0; }
    return atomic_load_explicit(&block->counters[counter], memory_order_relaxed);
}
