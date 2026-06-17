import { isIOSApp } from "@/platform/ios/webview";

export const canonicalDomain = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";

export const domain = () => window.location.hostname;

export { isIOSApp };

export const onCanonicalDomain = () =>
    [canonicalDomain, "localhost", "127.0.0.1"].includes(domain());

export const shareUrl = async (path: string) => {
    const url = new URL(path, window.location.origin + "/").href;
    if (navigator.share) {
        await navigator.share({ title: document.title || "TAGGR", url });
        return;
    }
    await navigator.clipboard.writeText(url);
};
