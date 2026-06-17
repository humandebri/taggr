// src/image-gallery/src/api.ts
// Provides the minimal anonymous query client required by the standalone image
// gallery without importing TAGGR's authenticated frontend API.

import { HttpAgent } from "@dfinity/agent";
import { CANISTER_ID, MAINNET_MODE } from "./env";
import { FileMap, GalleryPost } from "./types";

let agent: HttpAgent | null = null;
let rootKeyFetched = false;

const getAgent = async (): Promise<HttpAgent> => {
    if (agent == null) {
        agent = new HttpAgent(
            MAINNET_MODE && CANISTER_ID
                ? { host: `https://${CANISTER_ID}.ic0.app` }
                : {},
        );
    }
    if (!MAINNET_MODE && !rootKeyFetched) {
        await agent.fetchRootKey();
        rootKeyFetched = true;
    }
    return agent;
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
    typeof value == "object" && value != null && !Array.isArray(value);

const isFileTuple = (value: unknown): value is [number, number] =>
    Array.isArray(value) &&
    value.length == 2 &&
    typeof value[0] == "number" &&
    typeof value[1] == "number";

const parseFiles = (value: unknown): FileMap => {
    if (!isRecord(value)) return {};
    return Object.entries(value).reduce<FileMap>((files, [key, tuple]) => {
        if (isFileTuple(tuple) && key.includes("@")) {
            files[key] = tuple;
        }
        return files;
    }, {});
};

const parsePost = (value: unknown): GalleryPost | null => {
    if (!isRecord(value) || typeof value.id != "number") return null;
    return {
        id: value.id,
        files: parseFiles(value.files),
    };
};

const parsePostPair = (value: unknown): GalleryPost | null => {
    if (!Array.isArray(value) || value.length == 0) return null;
    return parsePost(value[0]);
};

const parsePosts = (value: unknown): GalleryPost[] => {
    if (!Array.isArray(value)) return [];
    return value
        .map(parsePostPair)
        .filter((post): post is GalleryPost => post != null);
};

const encodeJsonArg = (value: unknown): ArrayBuffer => {
    const bytes = new TextEncoder().encode(JSON.stringify(value));
    const buffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    return buffer;
};

export const queryUserPosts = async (
    domain: string,
    handle: string,
    page: number,
    offset: number,
): Promise<GalleryPost[]> => {
    if (!CANISTER_ID) {
        throw new Error("CANISTER_ID is not configured");
    }

    const params = [domain, handle, page, offset];
    const arg = encodeJsonArg(params);
    const activeAgent = await getAgent();
    const response = await activeAgent.query(CANISTER_ID, {
        methodName: "user_posts",
        arg,
    });

    if (response.status == "rejected") {
        return [];
    }

    const text = new TextDecoder().decode(response.reply.arg);
    return parsePosts(JSON.parse(text));
};
