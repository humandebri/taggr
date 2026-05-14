import * as React from "react";
import { cn } from "@/app/lib/cn";

export const Badge = ({
    className,
    ...props
}: React.HTMLAttributes<HTMLSpanElement>) => (
    <span
        className={cn(
            "inline-flex items-center rounded-md border border-[hsl(var(--border))] px-2 py-0.5 text-xs font-medium text-[hsl(var(--muted-foreground))]",
            className,
        )}
        {...props}
    />
);
