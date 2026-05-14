import { signal } from "@preact/signals";

export type ToastKind = "info" | "success" | "error";

export type ToastState = {
    kind: ToastKind;
    message: string;
};

export const booting = signal(true);
export const busy = signal(false);
export const toast = signal<ToastState | null>(null);
export const sidebarOpen = signal(false);

let toastTimer: number | undefined;

export const showToast = (
    kind: ToastKind,
    message: string,
    durationSecs = 3,
) => {
    toast.value = { kind, message };
    if (toastTimer !== undefined) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
        toast.value = null;
        toastTimer = undefined;
    }, durationSecs * 1000);
};

export const withBusy = async (task: () => Promise<void>) => {
    busy.value = true;
    try {
        await task();
    } finally {
        busy.value = false;
    }
};
