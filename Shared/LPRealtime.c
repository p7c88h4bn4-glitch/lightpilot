// LPRealtime.c
// Single-producer (render thread) / single-consumer (control queue) MIDI ring,
// plus atomic parameter slots with a dirty bitmask.

#include "LPRealtime.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define LP_RING_CAPACITY 1024u   // power of two
#define LP_RING_MASK (LP_RING_CAPACITY - 1u)

struct LPRealtime {
    _Atomic uint32_t head;                 // written by producer
    _Atomic uint32_t tail;                 // written by consumer
    uint32_t data[LP_RING_CAPACITY];
    _Atomic uint32_t paramBits[LP_PARAM_COUNT];
    _Atomic uint32_t dirty;
    _Atomic uint32_t dropped;
};

LPRealtime *lp_rt_create(void) {
    LPRealtime *rt = (LPRealtime *)calloc(1, sizeof(LPRealtime));
    if (!rt) { return NULL; }
    atomic_init(&rt->head, 0u);
    atomic_init(&rt->tail, 0u);
    atomic_init(&rt->dirty, 0u);
    atomic_init(&rt->dropped, 0u);
    for (uint32_t i = 0; i < LP_PARAM_COUNT; i++) {
        atomic_init(&rt->paramBits[i], 0u);
    }
    return rt;
}

void lp_rt_destroy(LPRealtime *rt) {
    free(rt);
}

bool lp_rt_push_midi(LPRealtime *rt, uint32_t packed) {
    if (!rt) { return false; }
    uint32_t head = atomic_load_explicit(&rt->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&rt->tail, memory_order_acquire);
    if (head - tail >= LP_RING_CAPACITY) {
        atomic_fetch_add_explicit(&rt->dropped, 1u, memory_order_relaxed);
        return false;
    }
    rt->data[head & LP_RING_MASK] = packed;
    atomic_store_explicit(&rt->head, head + 1u, memory_order_release);
    return true;
}

bool lp_rt_pop_midi(LPRealtime *rt, uint32_t *outPacked) {
    if (!rt || !outPacked) { return false; }
    uint32_t tail = atomic_load_explicit(&rt->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&rt->head, memory_order_acquire);
    if (tail == head) { return false; }
    *outPacked = rt->data[tail & LP_RING_MASK];
    atomic_store_explicit(&rt->tail, tail + 1u, memory_order_release);
    return true;
}

static uint32_t lp_float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float lp_bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

void lp_rt_set_param(LPRealtime *rt, uint32_t index, float value) {
    if (!rt || index >= LP_PARAM_COUNT) { return; }
    atomic_store_explicit(&rt->paramBits[index], lp_float_bits(value), memory_order_release);
    atomic_fetch_or_explicit(&rt->dirty, (1u << index), memory_order_acq_rel);
}

void lp_rt_store_param_quiet(LPRealtime *rt, uint32_t index, float value) {
    if (!rt || index >= LP_PARAM_COUNT) { return; }
    atomic_store_explicit(&rt->paramBits[index], lp_float_bits(value), memory_order_release);
}

float lp_rt_get_param(const LPRealtime *rt, uint32_t index) {
    if (!rt || index >= LP_PARAM_COUNT) { return 0.0f; }
    uint32_t bits = atomic_load_explicit((_Atomic uint32_t *)&rt->paramBits[index], memory_order_acquire);
    return lp_bits_float(bits);
}

uint32_t lp_rt_take_dirty(LPRealtime *rt) {
    if (!rt) { return 0u; }
    return atomic_exchange_explicit(&rt->dirty, 0u, memory_order_acq_rel);
}

uint32_t lp_rt_dropped(const LPRealtime *rt) {
    if (!rt) { return 0u; }
    return atomic_load_explicit((_Atomic uint32_t *)&rt->dropped, memory_order_relaxed);
}
