import { signal } from "@preact/signals";
import { Meta, Post, PostId } from "@/types";
import { CANISTER_ID } from "@/env";
import { domain } from "@/app/lib/domain";
import { requireApi } from "@/app/state/auth";
import { showToast } from "@/app/state/ui";

export type FeedMode = "NEW" | "HOT" | "REALMS" | "FOR_ME";

export const feedMode = signal<FeedMode>("HOT");
export const feedFiltered = signal(true);
export const feedPosts = signal<Post[]>([]);
export const feedLoading = signal(false);
export const feedPage = signal(0);
export const focusedPost = signal<Post | null>(null);
export const postDraft = signal("");
export const postRealm = signal("");
export const commentDraft = signal("");

const expandMeta = ([post, meta]: [Post, Meta]) => {
    post.meta = meta;
    return post;
};

export const loadPosts = async (ids: PostId[]) => {
    if (!CANISTER_ID) return [];
    const rows = (await requireApi().query<[Post, Meta][]>("posts", ids)) || [];
    return rows.map(expandMeta);
};

export const loadFeed = async (realm = "", reset = true) => {
    if (!CANISTER_ID) {
        feedPosts.value = [];
        feedLoading.value = false;
        return;
    }
    feedLoading.value = true;
    const page = reset ? 0 : feedPage.value + 1;
    const offset = reset || feedPosts.value.length === 0 ? 0 : feedPosts.value[0].id;
    let rows: [Post, Meta][] | null = null;
    if (feedMode.value === "FOR_ME") {
        rows = await requireApi().query("personal_feed", domain(), page, offset);
    } else if (feedMode.value === "REALMS") {
        rows = await requireApi().query("realms_posts", domain(), page, offset);
    } else if (feedMode.value === "HOT") {
        rows = await requireApi().query("hot_posts", domain(), realm, page, offset, !realm);
    } else {
        rows = await requireApi().query("last_posts", domain(), realm, page, offset, feedFiltered.value);
    }
    const nextPosts = (rows || []).map(expandMeta);
    feedPosts.value = reset ? nextPosts : feedPosts.value.concat(nextPosts);
    feedPage.value = page;
    feedLoading.value = false;
};

export const loadPost = async (id: number) => {
    if (!CANISTER_ID) {
        focusedPost.value = null;
        return;
    }
    const posts = await loadPosts([id]);
    focusedPost.value = posts[0] || null;
};

export const submitPost = async (realm = "") => {
    const body = postDraft.value.trim();
    const targetRealm = realm || postRealm.value;
    if (!body) return;
    const result = await requireApi().add_post(
        body,
        [],
        [],
        targetRealm ? [targetRealm] : [],
        [],
    );
    if (!result) {
        showToast("error", "Post call failed");
        return;
    }
    if (typeof result === "object" && "Err" in result) {
        showToast("error", String(result.Err));
        return;
    }
    const id = typeof result === "object" && "Ok" in result ? Number(result.Ok) : null;
    postDraft.value = "";
    postRealm.value = "";
    if (id !== null) window.location.hash = `#/post/${id}`;
};

export const submitComment = async (parent: Post) => {
    const body = commentDraft.value.trim();
    if (!body) return;
    const result = await requireApi().add_post(body, [], [parent.id], [], []);
    if (result && typeof result === "object" && "Err" in result) {
        showToast("error", String(result.Err));
        return;
    }
    commentDraft.value = "";
    await loadPost(parent.id);
};
