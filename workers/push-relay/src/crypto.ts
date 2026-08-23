const encoder = new TextEncoder();

export async function sha256Hex(value: string): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
    return [...new Uint8Array(digest)]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
}

export function base64Url(value: Uint8Array | string): string {
    const bytes = typeof value === "string" ? encoder.encode(value) : value;
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary)
        .replaceAll("+", "-")
        .replaceAll("/", "_")
        .replace(/=+$/, "");
}

export async function secretMatches(
    provided: string,
    expectedHash: string,
): Promise<boolean> {
    const providedHash = await crypto.subtle.digest(
        "SHA-256",
        encoder.encode(provided),
    );
    const expected = Uint8Array.from(
        expectedHash.match(/.{2}/g) ?? [],
        (pair) => Number.parseInt(pair, 16),
    );
    return (
        expected.byteLength === 32 &&
        crypto.subtle.timingSafeEqual(providedHash, expected)
    );
}
