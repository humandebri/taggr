import { toast } from "@/app/state/ui";
import { cn } from "@/app/lib/cn";

export const Toast = () => {
    if (!toast.value) return null;
    return (
        <div
            className={cn(
                "fixed right-4 top-4 z-50 max-w-sm rounded-lg border px-4 py-3 text-sm shadow-lg",
                toast.value.kind === "error" && "border-red-500/40 bg-red-950 text-red-50",
                toast.value.kind === "success" && "border-emerald-500/40 bg-emerald-950 text-emerald-50",
                toast.value.kind === "info" && "border-sky-500/40 bg-sky-950 text-sky-50",
            )}
        >
            {toast.value.message}
        </div>
    );
};
