// TAGGR iOS / BLS12-381 verification bridge.
// This exposes the single IC certificate verification primitive needed by Swift.

#ifndef TAGGR_BLS_VERIFIER_H
#define TAGGR_BLS_VERIFIER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool taggr_bls_verify_short_signature(
    const uint8_t *public_key,
    size_t public_key_len,
    const uint8_t *signature,
    size_t signature_len,
    const uint8_t *message,
    size_t message_len
);

#endif
