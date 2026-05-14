import { signal } from "@preact/signals";
import { Realm } from "@/types";
import { CANISTER_ID } from "@/env";
import { requireApi, reloadCache, reloadUser, user } from "@/app/state/auth";
import { showToast } from "@/app/state/ui";

export const joinedRealms = signal<{ name: string; realm: Realm }[]>([]);
export const activeRealm = signal<{ name: string; realm: Realm } | null>(null);
export const realmsIndex = signal<{ name: string; realm: Realm }[]>([]);
export const realmFormName = signal("");
export const realmFormDescription = signal("");
export const realmFormColor = signal("#5865f2");
export const realmFormAdult = signal(false);
export const realmFormCommentsOpen = signal(false);

const realmDefaults = (): Realm => ({
    cleanup_penalty: 10,
    controllers: user.value ? [user.value.id] : [],
    description: realmFormDescription.value,
    filter: {
        age_days: 0,
        safe: false,
        balance: 0,
        num_followers: 0,
    },
    label_color: realmFormColor.value,
    logo: "",
    max_downvotes: window.backendCache?.config.default_max_downvotes || 5,
    num_members: 0,
    num_posts: 0,
    theme: "",
    whitelist: [],
    last_setting_update: 0,
    last_update: 0,
    revenue: 0,
    created: 0,
    posts: [],
    adult_content: realmFormAdult.value,
    comments_filtering: !realmFormCommentsOpen.value,
});

const pairs = (names: string[], realms: Realm[]) =>
    names
        .map((name, index) => {
            const realm = realms[index];
            return realm ? { name, realm } : null;
        })
        .filter((item): item is { name: string; realm: Realm } => item !== null);

export const loadJoinedRealms = async () => {
    if (!CANISTER_ID) {
        joinedRealms.value = [];
        return;
    }
    const names = user.value?.realms || [];
    if (names.length === 0) {
        joinedRealms.value = [];
        return;
    }
    const realms = (await requireApi().query<Realm[]>("realms", names)) || [];
    joinedRealms.value = pairs(names, realms);
};

export const loadRealm = async (name: string) => {
    if (!CANISTER_ID) {
        activeRealm.value = null;
        window.realm = "";
        return;
    }
    if (!name) {
        activeRealm.value = null;
        return;
    }
    const realms = (await requireApi().query<Realm[]>("realms", [name])) || [];
    activeRealm.value = realms[0] ? { name, realm: realms[0] } : null;
    window.realm = activeRealm.value?.name || "";
};

export const loadRealmsIndex = async () => {
    if (!CANISTER_ID) {
        realmsIndex.value = [];
        return;
    }
    const stats = window.backendCache?.stats.realms || 50;
    const result =
        (await requireApi().query<[string, Realm][]>("realms", [], 0, stats)) ||
        [];
    realmsIndex.value = result.map(([name, realm]) => ({ name, realm }));
};

export const toggleRealmMembership = async (name: string) => {
    const response = await requireApi().call<{ Err?: string }>(
        "toggle_realm_membership",
        name,
    );
    if (response?.Err) {
        showToast("error", response.Err);
        return;
    }
    await reloadUser();
    await Promise.all([loadJoinedRealms(), loadRealm(name)]);
};

export const createRealm = async () => {
    const name = realmFormName.value.trim().toUpperCase();
    if (!name || !realmFormDescription.value.trim()) {
        showToast("error", "Realm name and description are required");
        return;
    }
    const response = await requireApi().call<{ Err?: string }>(
        "create_realm",
        name,
        realmDefaults(),
    );
    if (response?.Err) {
        showToast("error", response.Err);
        return;
    }
    await requireApi().call("toggle_realm_membership", name);
    realmFormName.value = "";
    realmFormDescription.value = "";
    await Promise.all([reloadCache(), reloadUser()]);
    await loadJoinedRealms();
    window.location.hash = `#/realm/${name}`;
};
