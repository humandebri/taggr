import { route } from "@/app/state/route";
import { loadFeed, postRealm } from "@/app/state/feed";
import { loadJoinedRealms, loadRealm, loadRealmsIndex } from "@/app/state/realms";
import { user } from "@/app/state/auth";
import { loadPost } from "@/app/state/feed";
import { loadProfile } from "@/app/profile/ProfilePage";

export const loadRouteData = async () => {
    const current = route.value;
    document.title = current.name === "home" ? "TAGGR" : `TAGGR: ${current.name}`;
    if (user.value) await loadJoinedRealms();

    if (current.name === "realm") {
        const name = current.params[0]?.toUpperCase() || "";
        await loadRealm(name);
        await loadFeed(name);
        return;
    }

    window.realm = "";
    await loadRealm("");
    if (current.name === "post") {
        await loadPost(Number(current.params[0]));
        return;
    }
    if (current.name === "new") {
        postRealm.value = current.params[0]?.toUpperCase() || "";
        return;
    }
    if (current.name === "realms") {
        await loadRealmsIndex();
        return;
    }
    if (current.name === "user") {
        await loadProfile(current.params[0] || "");
        return;
    }
    if (["home", ""].includes(current.name)) {
        await loadFeed("");
    }
};
