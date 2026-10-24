// LPRealtime.h
// Lock-free handoff between the AU render thread and the non-realtime control queue.
// The render thread only ever calls lp_rt_push_midi and lp_rt_set_param: no locks,
// no allocation, no Objective-C/Swift runtime work.

#ifndef LPRealtime_h
#define LPRealtime_h

#include <stdint.h>
#include <stdbool.h>

#define LP_PARAM_COUNT 16

typedef struct LPRealtime LPRealtime;

LPRealtime *lp_rt_create(void);
void lp_rt_destroy(LPRealtime *rt);

/// Render thread: enqueue a packed 3-byte MIDI message (status | d1 << 8 | d2 << 16).
/// Returns false and increments the drop counter when the ring is full.
bool lp_rt_push_midi(LPRealtime *rt, uint32_t packed);

/// Control queue: dequeue one MIDI message. Returns false when empty.
bool lp_rt_pop_midi(LPRealtime *rt, uint32_t *outPacked);

/// Any thread: store a parameter value and mark it dirty.
void lp_rt_set_param(LPRealtime *rt, uint32_t index, float value);

/// Any thread: store a parameter value without marking it dirty (used to echo
/// values the control queue itself already applied).
void lp_rt_store_param_quiet(LPRealtime *rt, uint32_t index, float value);

/// Any thread: read the latest parameter value.
float lp_rt_get_param(const LPRealtime *rt, uint32_t index);

/// Control queue: atomically take and clear the dirty mask.
uint32_t lp_rt_take_dirty(LPRealtime *rt);

/// Number of MIDI messages dropped because the ring was full.
uint32_t lp_rt_dropped(const LPRealtime *rt);

#endif /* LPRealtime_h */
