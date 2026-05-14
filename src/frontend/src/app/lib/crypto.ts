export const hashIterations = 15000;

export const hash = async (value: string, iterations = hashIterations) => {
    let digest = new TextEncoder().encode(value);
    for (let index = 0; index < iterations; index += 1) {
        digest = new Uint8Array(await crypto.subtle.digest("SHA-256", digest));
    }
    return digest;
};
