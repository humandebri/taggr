import { signal } from "@preact/signals";

export type Route = {
    name: string;
    params: string[];
    hash: string;
};

export const parseRoute = (): Route => {
    const rawHash = window.location.hash || "#/";
    const parts = rawHash.replace(/^#\/?/, "").split("/").filter(Boolean);
    const [name = "home", ...params] = parts.map(decodeURIComponent);
    return { name, params, hash: rawHash };
};

export const route = signal<Route>(parseRoute());

export const navigate = (path: string) => {
    const normalized = path.startsWith("#/") ? path : `#/${path}`;
    if (window.location.hash === normalized) {
        route.value = parseRoute();
        return;
    }
    window.location.hash = normalized;
};

export const installRouteListener = (onChange: () => void) => {
    const sync = () => {
        route.value = parseRoute();
        onChange();
    };
    window.addEventListener("hashchange", sync);
    return sync;
};
