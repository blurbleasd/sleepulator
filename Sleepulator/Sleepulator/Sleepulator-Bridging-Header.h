//
//  Sleepulator-Bridging-Header.h
//  Sleepulator
//
//  Swift↔C bridge for the lock-free audio param hand-off. Kept minimal on purpose:
//  it exposes ONLY an opaque release/acquire index cell (see SLPAtomicIndex.c). The
//  _Atomic field lives entirely on the C side — Swift can't represent _Atomic, so the
//  type is forward-declared opaque here and Swift only ever holds the pointer.
//

#ifndef SLEEPULATOR_BRIDGING_HEADER_H
#define SLEEPULATOR_BRIDGING_HEADER_H

#include <stdint.h>

// Opaque single-producer/single-consumer index cell with release/acquire ordering.
// Used by GenerativeAudioEngine to publish which slot of its double-buffered render
// params the audio thread should read. Producer = main thread; consumer = render thread.
typedef struct SLPAtomicIndex SLPAtomicIndex;

// Allocate a cell initialized to `initial`. Caller owns it; pair with SLPAtomicIndexDestroy.
SLPAtomicIndex *SLPAtomicIndexCreate(intptr_t initial);

// Free a cell. Must not be called while the render thread can still load from it.
void SLPAtomicIndexDestroy(SLPAtomicIndex *cell);

// Consumer (audio render thread): acquire-load the published index. Lock-free, RT-safe.
intptr_t SLPAtomicIndexLoadAcquire(const SLPAtomicIndex *cell);

// Producer (main thread): release-store the index after writing the param slot, so the
// param-struct writes are guaranteed visible to the consumer before the index publish.
void SLPAtomicIndexStoreRelease(SLPAtomicIndex *cell, intptr_t value);

#endif /* SLEEPULATOR_BRIDGING_HEADER_H */
