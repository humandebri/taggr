// src/image-gallery/src/types.ts
// Keeps only the public post fields needed to derive image URLs from TAGGR
// query responses.

export type PostId = number;

export type FileMap = {
    [key: string]: [number, number];
};

export type GalleryPost = {
    id: PostId;
    files: FileMap;
};

export type GalleryImage = {
    id: string;
    postId: PostId;
    src: string;
    postUrl: string;
};

