import { Post } from "@/types";

export const timeAgo = (timestamp: BigInt | bigint | number) => {
    const millis = Number(timestamp) / 1000000;
    const diff = Date.now() - millis;
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;
    if (diff < minute) return `${Math.max(1, Math.round(diff / 1000))}s`;
    if (diff < hour) return `${Math.round(diff / minute)}m`;
    if (diff < day) return `${Math.round(diff / hour)}h`;
    return new Intl.DateTimeFormat(undefined, {
        month: "short",
        day: "numeric",
    }).format(millis);
};

export const initials = (value: string) =>
    value
        .replace(/[^a-z0-9]/gi, " ")
        .trim()
        .split(/\s+/)
        .slice(0, 2)
        .map((part) => part[0]?.toUpperCase() || "")
        .join("") || "T";

export const postTitle = (post: Post) =>
    (post.body.split(/\n+/).find((line) => line.trim()) || "")
        .trim()
        .slice(0, 80) || `Post #${post.id}`;
