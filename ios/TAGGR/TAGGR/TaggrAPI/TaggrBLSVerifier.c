// TAGGR iOS / blst adapter.
// IC certificates use the same BLS verifyShortSignature shape as @dfinity/agent.

#include "TaggrBLSVerifier.h"

#include <string.h>

#include "../../ThirdParty/blst/bindings/blst.h"

bool taggr_bls_verify_short_signature(
    const uint8_t *public_key,
    size_t public_key_len,
    const uint8_t *signature,
    size_t signature_len,
    const uint8_t *message,
    size_t message_len
) {
    static const char dst[] = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";
    blst_p2_affine pk;
    blst_p1_affine sig;

    if (public_key_len != 96 || signature_len != 48) {
        return false;
    }
    if (blst_p2_uncompress(&pk, public_key) != BLST_SUCCESS) {
        return false;
    }
    if (blst_p1_uncompress(&sig, signature) != BLST_SUCCESS) {
        return false;
    }
    return blst_core_verify_pk_in_g2(
        &pk,
        &sig,
        true,
        message,
        message_len,
        (const byte *)dst,
        strlen(dst),
        NULL,
        0
    ) == BLST_SUCCESS;
}
