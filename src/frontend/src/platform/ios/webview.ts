export const isIOSApp = () =>
    /\bTAGGR-iOS\b/.test(navigator.userAgent) ||
    window.__TAGGR_IOS_APP__ === true;

export const internetIdentityTimeoutMs = 20000;
