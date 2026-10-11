package org.taggr.android.data

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

object InviteQR {
    fun matrix(url: String) =
        QRCodeWriter()
            .encode(
                url.also { require(it.length <= 1024) },
                BarcodeFormat.QR_CODE,
                0,
                0,
                mapOf(EncodeHintType.MARGIN to 4),
            )
}
