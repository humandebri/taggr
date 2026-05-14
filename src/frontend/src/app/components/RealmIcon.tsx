import { Realm } from "@/types";
import { initials } from "@/app/lib/format";
import { cn } from "@/app/lib/cn";

export const RealmIcon = ({
    name,
    realm,
    active,
    size = 48,
}: {
    name: string;
    realm?: Realm;
    active?: boolean;
    size?: number;
}) => {
    const style = {
        width: `${size}px`,
        height: `${size}px`,
        backgroundColor: realm?.label_color || "#5865f2",
    };
    return (
        <div
            title={name}
            style={style}
            data-testid={`realm-rail-${name}`}
            className={cn(
                "flex shrink-0 items-center justify-center overflow-hidden rounded-2xl text-sm font-bold text-white shadow-sm transition-all hover:rounded-xl",
                active && "active_realm_icon rounded-xl ring-2 ring-[hsl(var(--primary))]",
            )}
        >
            {realm?.logo ? (
                <img
                    alt={`${name} logo`}
                    className="h-full w-full object-cover"
                    src={`data:image/png;base64,${realm.logo}`}
                />
            ) : (
                initials(name)
            )}
        </div>
    );
};
