import * as React from "react";
import { cn } from "@/app/lib/cn";

export const Card = React.forwardRef<
    HTMLDivElement,
    React.HTMLAttributes<HTMLDivElement>
>(({ className, ...props }, ref) => (
    <div
        ref={ref}
        className={cn(
            "rounded-lg border border-[hsl(var(--border))] bg-[hsl(var(--popover))] text-[hsl(var(--popover-foreground))] shadow-sm",
            className,
        )}
        {...props}
    />
));
Card.displayName = "Card";
