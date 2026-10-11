package org.taggr.android.data

import java.math.BigDecimal
import java.math.BigInteger

object WalletAmounts {
    fun token(raw: BigInteger, decimals: Int): String {
        require(raw.signum() >= 0 && decimals in 0..255)
        return BigDecimal(raw, decimals).stripTrailingZeros().toPlainString()
    }
}
