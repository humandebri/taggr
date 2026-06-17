// src/image-gallery/src/index.tsx
// Renders a standalone public gallery by paging TAGGR posts for one handle and
// deriving image URLs from each post's bucket-backed file references.

import * as React from "react";
import { createRoot } from "react-dom/client";
import { queryUserPosts } from "./api";
import { MAINNET_MODE, TAGGR_DOMAIN } from "./env";
import { GalleryImage, GalleryPost } from "./types";

const PAGE_ZERO_OFFSET = 0;

const rawImageUrl = (bucketId: string, offset: number, len: number): string => {
    const host = MAINNET_MODE
        ? `https://${bucketId}.raw.icp0.io`
        : `http://${bucketId}.raw.localhost:8080`;
    return `${host}/image?offset=${offset}&len=${len}`;
};

const postUrl = (postId: number): string => {
    const base = MAINNET_MODE
        ? `https://${TAGGR_DOMAIN}`
        : "http://localhost:9090";
    return `${base}/#/post/${postId}`;
};

const imagesFromPosts = (posts: GalleryPost[]): GalleryImage[] =>
    posts.flatMap((post) =>
        Object.entries(post.files).flatMap(([key, [offset, len]]) => {
            const parts = key.split("@");
            if (parts.length != 2 || !parts[0] || !parts[1]) return [];
            return [
                {
                    id: `${post.id}:${key}`,
                    postId: post.id,
                    src: rawImageUrl(parts[1], offset, len),
                    postUrl: postUrl(post.id),
                },
            ];
        }),
    );

const initialHandle = (): string =>
    new URLSearchParams(location.search).get("user")?.trim() || "";

const replaceHandleUrl = (handle: string) => {
    const params = new URLSearchParams(location.search);
    if (handle) params.set("user", handle);
    else params.delete("user");
    history.replaceState(null, "", `${location.pathname}?${params.toString()}`);
};

const Gallery = () => {
    const [handle, setHandle] = React.useState(initialHandle);
    const [input, setInput] = React.useState(initialHandle);
    const [page, setPage] = React.useState(0);
    const [images, setImages] = React.useState<GalleryImage[]>([]);
    const [loading, setLoading] = React.useState(false);
    const [error, setError] = React.useState("");
    const [hasMore, setHasMore] = React.useState(false);

    const loadPage = React.useCallback(
        async (pageToLoad: number, reset: boolean) => {
            if (!handle) return;
            setLoading(true);
            setError("");
            try {
                const posts = await queryUserPosts(
                    TAGGR_DOMAIN,
                    handle,
                    pageToLoad,
                    PAGE_ZERO_OFFSET,
                );
                const nextImages = imagesFromPosts(posts);
                setImages((current) =>
                    reset ? nextImages : [...current, ...nextImages],
                );
                setHasMore(posts.length > 0);
                setPage(pageToLoad);
            } catch (loadError) {
                setError(
                    loadError instanceof Error
                        ? loadError.message
                        : String(loadError),
                );
                setHasMore(false);
            } finally {
                setLoading(false);
            }
        },
        [handle],
    );

    React.useEffect(() => {
        setImages([]);
        setPage(0);
        setHasMore(false);
        if (handle) {
            replaceHandleUrl(handle);
            loadPage(0, true);
        }
    }, [handle, loadPage]);

    const submit = (event: React.FormEvent<HTMLFormElement>) => {
        event.preventDefault();
        const nextHandle = input.trim();
        setHandle(nextHandle);
        if (!nextHandle) {
            setImages([]);
            setError("");
            setHasMore(false);
            replaceHandleUrl("");
        }
    };

    return (
        <section className="shell">
            <header className="topbar">
                <a className="brand" href={`https://${TAGGR_DOMAIN}`}>
                    TAGGR Images
                </a>
                <form className="search" onSubmit={submit}>
                    <input
                        value={input}
                        onChange={(event) => setInput(event.target.value)}
                        placeholder="handle"
                        aria-label="TAGGR handle"
                    />
                    <button type="submit">Open</button>
                </form>
            </header>

            <div className="summary">
                {handle ? (
                    <>
                        <h1>@{handle}</h1>
                        <p>Public images from TAGGR posts on {TAGGR_DOMAIN}</p>
                    </>
                ) : (
                    <>
                        <h1>Enter a handle</h1>
                        <p>Use ?user=handle or search above.</p>
                    </>
                )}
            </div>

            {error && <div className="notice error">{error}</div>}
            {loading && images.length == 0 && (
                <div className="notice">Loading images...</div>
            )}
            {!loading && handle && images.length == 0 && !error && (
                <div className="notice">No public images found.</div>
            )}

            {images.length > 0 && (
                <div className="grid">
                    {images.map((image) => (
                        <a
                            className="tile"
                            href={image.postUrl}
                            key={image.id}
                            title={`Open post #${image.postId}`}
                        >
                            <img
                                src={image.src}
                                alt={`TAGGR post ${image.postId}`}
                                loading="lazy"
                            />
                            <span>#{image.postId}</span>
                        </a>
                    ))}
                </div>
            )}

            {handle && hasMore && (
                <div className="actions">
                    <button
                        type="button"
                        disabled={loading}
                        onClick={() => loadPage(page + 1, false)}
                    >
                        {loading ? "Loading..." : "Load more"}
                    </button>
                </div>
            )}
        </section>
    );
};

const root = document.getElementById("app");
if (!root) throw new Error("Missing #app root");
createRoot(root).render(
    <React.StrictMode>
        <Gallery />
    </React.StrictMode>,
);

