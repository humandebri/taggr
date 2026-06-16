import { Compass, Home, Plus } from "lucide-react";
import { route, navigate } from "@/app/state/route";
import { joinedRealms } from "@/app/state/realms";
import { user, monoRealm } from "@/app/state/auth";
import { RealmIcon } from "@/app/components/RealmIcon";
import { Button } from "@/app/ui/button";
import { cn } from "@/app/lib/cn";

const activeRealmName = () =>
    route.value.name === "realm"
        ? route.value.params[0]?.toUpperCase() || ""
        : "";

export const ServerRail = () => {
    if (!user.value || monoRealm.value) return null;
    const current = activeRealmName();
    return (
        <nav
            data-testid="realm-rail"
            className="mobile-realm-rail fixed bottom-0 left-0 right-0 z-30 flex items-center gap-3 overflow-x-auto border-t border-[hsl(var(--border))] bg-[#111214]/95 px-3 backdrop-blur md:bottom-auto md:right-auto md:top-0 md:w-20 md:flex-col md:overflow-y-auto md:border-r md:border-t-0 md:py-4"
        >
            <Button
                aria-label="Home"
                title="Home"
                size="icon"
                variant={route.value.name === "home" ? "default" : "secondary"}
                className="shrink-0 rounded-2xl"
                onClick={() => navigate("home")}
            >
                <Home className="h-5 w-5" />
            </Button>
            <div className="h-8 w-px bg-[hsl(var(--border))] md:h-px md:w-10" />
            <div className="flex gap-3 md:flex-col">
                {joinedRealms.value.map(({ name, realm }) => (
                    <button
                        key={name}
                        className={cn(
                            "rounded-2xl outline-none focus-visible:ring-2 focus-visible:ring-[hsl(var(--ring))]",
                        )}
                        onClick={() => navigate(`realm/${name}`)}
                    >
                        <RealmIcon
                            name={name}
                            realm={realm}
                            active={current === name}
                        />
                    </button>
                ))}
            </div>
            <div className="ml-auto flex gap-2 md:mt-auto md:ml-0 md:flex-col">
                <Button
                    aria-label="Explore realms"
                    title="Explore realms"
                    size="icon"
                    variant="secondary"
                    className="rounded-2xl"
                    onClick={() => navigate("realms")}
                >
                    <Compass className="h-5 w-5" />
                </Button>
                <Button
                    aria-label="Create realm"
                    title="Create realm"
                    size="icon"
                    variant="secondary"
                    className="hidden rounded-2xl md:inline-flex"
                    onClick={() => navigate("realms/create")}
                >
                    <Plus className="h-5 w-5" />
                </Button>
            </div>
        </nav>
    );
};
