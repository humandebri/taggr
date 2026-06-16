import { navigate, route } from "@/app/state/route";
import { booting } from "@/app/state/ui";
import { user, principalId } from "@/app/state/auth";
import { ServerRail } from "@/app/shell/ServerRail";
import { TopBar } from "@/app/shell/TopBar";
import { Toast } from "@/app/shell/Toast";
import { AuthPage } from "@/app/auth/AuthPage";
import { FeedView } from "@/app/feed/FeedView";
import { Composer } from "@/app/feed/Composer";
import { PostPage } from "@/app/feed/PostPage";
import { RealmHome } from "@/app/realm/RealmHome";
import { RealmsPage } from "@/app/realm/RealmsPage";
import { SettingsPage, WelcomePage } from "@/app/settings/SettingsPage";
import { ProfilePage } from "@/app/profile/ProfilePage";
import {
    isLegacyRoute,
    LegacyRoute,
    requiresLegacyPrincipal,
    requiresLegacyUser,
} from "@/app/legacy/LegacyRoute";

const requiresPrincipal = () => {
    const current = route.value;
    return (
        ["new", "settings"].includes(current.name) ||
        (current.name === "realms" && current.params[0] === "create") ||
        requiresLegacyPrincipal(current)
    );
};

const Screen = () => {
    const current = route.value;
    if (current.name === "sign-in") return <AuthPage />;
    if (current.name === "sign-up") return <AuthPage signUp />;
    if (current.name === "welcome") {
        if (user.value) {
            navigate("home");
            return null;
        }
        if (!principalId.value) {
            return <AuthPage signUp inviteCode={current.params[0] || ""} />;
        }
        return <WelcomePage invite={current.params[0] || ""} />;
    }
    if (requiresLegacyUser(current) && !user.value) {
        return <AuthPage />;
    }
    if (!principalId.value && requiresPrincipal()) {
        return <AuthPage />;
    }
    if (isLegacyRoute(current)) {
        return <LegacyRoute />;
    }
    if (current.name === "realm") return <RealmHome />;
    if (current.name === "realms") return <RealmsPage />;
    if (current.name === "new") return <Composer />;
    if (current.name === "post") return <PostPage />;
    if (current.name === "settings") return <SettingsPage />;
    if (current.name === "user") return <ProfilePage />;
    if (
        ["inbox", "tokens", "dashboard", "stats", "whitepaper"].includes(
            current.name,
        )
    ) {
        return <LegacyRoute />;
    }
    return <FeedView />;
};

export const App = () => (
    <div className="min-h-screen bg-[hsl(var(--background))] text-[hsl(var(--foreground))]">
        <Toast />
        {booting.value ? (
            <div className="flex min-h-screen items-center justify-center text-sm text-[hsl(var(--muted-foreground))]">
                Loading TAGGR...
            </div>
        ) : (
            <>
                <ServerRail />
                <div
                    className={
                        user.value ? "app-content-with-rail md:pl-20" : ""
                    }
                >
                    <TopBar />
                    <Screen />
                </div>
            </>
        )}
    </div>
);
