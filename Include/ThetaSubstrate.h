#ifndef ThetaSubstrate_h
#define ThetaSubstrate_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Load libsubstrate / CydiaSubstrate and resolve MSHookFunction. Safe to call repeatedly. */
bool ThetaSubstrateLoad(void);

/** Inline hook at `symbol` (from dlsym). No-op if substrate or symbol is missing. */
void ThetaMSHookFunction(void *symbol, void *replace, void **result);

/**
 * Resolve a C symbol in the main Instagram executable (not framework GOT stubs).
 * Returns NULL if not found or not defined in the app binary.
 */
void *ThetaResolveInstagramExecutableSymbol(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* ThetaSubstrate_h */
