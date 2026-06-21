//
//  SLPAtomicIndex.c
//  Sleepulator
//
//  Lock-free SPSC index hand-off for GenerativeAudioEngine's double-buffered render
//  params. Release/acquire is the minimum ordering that fixes the latent reordering race:
//  without it, the audio render thread could observe the newly published index while the
//  param-struct write to that slot is not yet visible (or speculate the param load ahead of
//  the index load). On ARM64 the aligned word load/store itself won't tear; the bug is
//  ordering, not tearing. Never take a lock on the render thread — this stays lock-free
//  after create().
//

#include "Sleepulator-Bridging-Header.h"

#include <stdatomic.h>
#include <stdlib.h>

struct SLPAtomicIndex {
    _Atomic(intptr_t) value;
};

SLPAtomicIndex *SLPAtomicIndexCreate(intptr_t initial) {
    SLPAtomicIndex *cell = (SLPAtomicIndex *)malloc(sizeof(SLPAtomicIndex));
    if (cell) {
        atomic_init(&cell->value, initial);
    }
    return cell;
}

void SLPAtomicIndexDestroy(SLPAtomicIndex *cell) {
    free(cell);
}

intptr_t SLPAtomicIndexLoadAcquire(const SLPAtomicIndex *cell) {
    // Casting away const is fine: atomic_load_explicit takes a non-const volatile pointer,
    // but an acquire load does not modify observable object state.
    return atomic_load_explicit(&((SLPAtomicIndex *)cell)->value, memory_order_acquire);
}

void SLPAtomicIndexStoreRelease(SLPAtomicIndex *cell, intptr_t value) {
    atomic_store_explicit(&cell->value, value, memory_order_release);
}
