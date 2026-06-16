import {
    Bell,
    LogIn,
    LogOut,
    PenSquare,
    Settings,
    UserRound,
} from "lucide-react";
import { route, navigate } from "@/app/state/route";
import { signOut, user } from "@/app/state/auth";
import { Button } from "@/app/ui/button";
import {
    DropdownMenu,
    DropdownMenuContent,
    DropdownMenuItem,
    DropdownMenuLabel,
    DropdownMenuSeparator,
    DropdownMenuTrigger,
} from "@/app/ui/dropdown-menu";

const title = () => {
    if (route.value.name === "realm")
        return route.value.params[0]?.toUpperCase() || "Realm";
    if (route.value.name === "post")
        return `Post #${route.value.params[0] || ""}`;
    if (route.value.name === "realms") return "Realms";
    if (route.value.name === "settings") return "Settings";
    if (route.value.name === "user") return `@${route.value.params[0] || ""}`;
    return "TAGGR";
};

const newPostRoute = () => {
    if (route.value.name !== "realm") return "new";
    const realm = route.value.params[0]?.toUpperCase();
    return realm ? `new/${realm}` : "new";
};

export const TopBar = () => (
    <header className="sticky top-0 z-20 flex min-h-14 items-center gap-2 border-b border-[hsl(var(--border))] bg-[hsl(var(--background))]/95 px-3 py-2 backdrop-blur sm:gap-3 sm:px-4">
        <div className="min-w-0 flex-1">
            <h1 className="truncate text-sm font-semibold">{title()}</h1>
        </div>
        {user.value ? (
            <>
                <Button
                    aria-label="New post"
                    className="topbar-post-button"
                    size="sm"
                    onClick={() => navigate(newPostRoute())}
                >
                    <PenSquare className="h-4 w-4" />
                    <span className="topbar-post-label">POST</span>
                </Button>
                <Button
                    size="icon"
                    variant="ghost"
                    title="Inbox"
                    onClick={() => navigate("inbox")}
                >
                    <Bell className="h-5 w-5" />
                </Button>
                <DropdownMenu>
                    <DropdownMenuTrigger>
                        <Button
                            asChild
                            size="icon"
                            variant="secondary"
                            data-testid="toggle-user-section"
                        >
                            <span>
                                <UserRound className="h-5 w-5" />
                            </span>
                        </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                        <DropdownMenuLabel>
                            {user.value.name.toUpperCase()}
                        </DropdownMenuLabel>
                        <DropdownMenuSeparator />
                        <DropdownMenuItem
                            onClick={() => navigate(`user/${user.value?.name}`)}
                        >
                            <UserRound className="h-4 w-4" /> Profile
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => navigate("settings")}>
                            <Settings className="h-4 w-4" /> Settings
                        </DropdownMenuItem>
                        <DropdownMenuSeparator />
                        <DropdownMenuItem onClick={signOut}>
                            <LogOut className="h-4 w-4" /> SIGN OUT
                        </DropdownMenuItem>
                    </DropdownMenuContent>
                </DropdownMenu>
            </>
        ) : (
            <Button size="sm" onClick={() => navigate("sign-in")}>
                <LogIn className="h-4 w-4" />
                SIGN IN
            </Button>
        )}
    </header>
);
