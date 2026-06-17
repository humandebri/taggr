import {
    AuthClient,
    type AuthClientCreateOptions,
} from "@dfinity/auth-client";
import { Ed25519KeyIdentity } from "@dfinity/identity";
import { signal } from "@preact/signals";
import { ApiGenerator, Backend } from "@/api";
import { Config, DomainConfig, getJournal, getMonoRealm, Stats, User } from "@/types";
import { CANISTER_ID, II_URL, MAINNET_MODE } from "@/env";
import { domain } from "@/app/lib/domain";
import { hash } from "@/app/lib/crypto";
import { navigate } from "@/app/state/route";
import { booting, showToast } from "@/app/state/ui";
import { defaultConfig, defaultStats } from "@/app/state/defaults";

export type BackendCache = {
    recent_tags: [string, number][];
    stats: Stats;
    config: Config;
    domains: { [domain: string]: DomainConfig };
};

export const api = signal<Backend | null>(null);
export const mainnetApi = signal<Backend | null>(null);
export const authClient = signal<AuthClient | null>(null);
export const principalId = signal("");
export const user = signal<User | null>(null);
export const backendCache = signal<BackendCache | null>(null);
export const monoRealm = signal<string | null>(null);
export const hideRealmless = signal(false);
export const lastVisit = signal<BigInt>(BigInt(0));

const refreshRateMs = 10 * 60 * 1000;
const staleActivityMs = 10 * 60 * 1000;
let lastSavedUpgrade: number | null = null;
let lastInternetIdentityError: { message: string; timestamp: number } | null = null;

const errorText = (error: unknown) =>
    error instanceof Error ? error.message : String(error);

const reportInternetIdentityError = (message: string) => {
    const now = Date.now();
    if (
        lastInternetIdentityError &&
        lastInternetIdentityError.message === message &&
        now - lastInternetIdentityError.timestamp < 1000
    ) {
        return;
    }
    lastInternetIdentityError = { message, timestamp: now };
    console.error(`[TAGGR II] ${message}`);
    showToast("error", `Internet Identity failed: ${message}`, 8);
};

const microSecsSince = (timestamp: BigInt) =>
    Number(new Date()) - Number(timestamp) / 1000000;

const isSecureSeedPhrase = (seedPhrase: string) =>
    /^(?=.*?[A-Z])(?=.*?[0-9])(?=.*?[!@#$%^&*()_+\-=[\]{};':"\\|,.<>/?]).{8,}$/.test(
        seedPhrase,
    );

const isBip39SeedPhrase = (seedPhrase: string) => {
    const words = seedPhrase.trim().replace(/\s+/g, " ").split(" ");
    if (![12, 15, 18, 21, 24].includes(words.length)) return false;
    return words.every((word) => /^[a-z]{3,8}$/.test(word));
};

const routeAfterLogin = (signUp: boolean, inviteCode = "") => {
    if (!signUp && user.value) return "home";
    return inviteCode ? `welcome/${inviteCode}` : "welcome";
};

const handleUpgradeNotice = (stats: Stats) => {
    const nextUpgrade = stats.last_release?.timestamp;
    if (!nextUpgrade) return;
    if (lastSavedUpgrade === null) {
        lastSavedUpgrade = nextUpgrade;
        return;
    }
    if (lastSavedUpgrade === nextUpgrade) return;
    lastSavedUpgrade = nextUpgrade;
    const banner = document.getElementById("upgrade_banner");
    if (!banner) {
        showToast("info", "New app version is available. Reload to update.", 8);
        return;
    }
    banner.innerHTML = "New app version is available! Click me to reload.";
    banner.onclick = () => {
        banner.innerHTML = "RELOADING...";
        setTimeout(() => location.reload(), 100);
    };
    banner.style.display = "block";
};

export const requireApi = () => {
    const current = api.value;
    if (!current) throw new Error("API is not ready");
    return current;
};

export const instantiateApi = async () => {
    const createOptions: AuthClientCreateOptions = {
        idleOptions: { disableIdle: true },
    };
    const client = await AuthClient.create(createOptions);
    authClient.value = client;
    window.authClient = client;

    let identity = undefined;
    if (await client.isAuthenticated()) {
        identity = client.getIdentity();
    } else {
        const serializedIdentity = localStorage.getItem("IDENTITY");
        if (serializedIdentity) {
            identity = Ed25519KeyIdentity.fromJSON(serializedIdentity);
        }
    }

    const nextApi = ApiGenerator(MAINNET_MODE, identity);
    api.value = nextApi;
    mainnetApi.value = ApiGenerator(true, identity);
    window.api = nextApi;
    window.mainnet_api = mainnetApi.value;
    if (identity) {
        principalId.value = identity.getPrincipal().toString();
        window.principalId = principalId.value;
    }
};

export const reloadCache = async () => {
    if (!CANISTER_ID) {
        const nextCache = {
            recent_tags: [],
            stats: defaultStats,
            config: defaultConfig,
            domains: {},
        };
        backendCache.value = nextCache;
        window.backendCache = nextCache;
        monoRealm.value = null;
        hideRealmless.value = false;
        showToast("info", "Backend cache unavailable in local visual mode");
        return;
    }
    const currentApi = requireApi();
    const [recentTags, stats, config, domainsCfgResp] = await Promise.all([
        currentApi.query<[string, number][]>("recent_tags", domain(), "", 500),
        currentApi.query<Stats>("stats"),
        currentApi.query<Config>("config"),
        currentApi.query<{ [domain: string]: DomainConfig }>("domains", domain()),
    ]);
    if (!stats || !config) {
        showToast("error", "Backend cache failed to load");
        return;
    }
    const nextCache = {
        recent_tags: recentTags || [],
        stats,
        config,
        domains: domainsCfgResp || {},
    };
    backendCache.value = nextCache;
    window.backendCache = nextCache;
    handleUpgradeNotice(stats);

    const domainCfg = nextCache.domains[domain()];
    monoRealm.value = getMonoRealm(domainCfg);
    hideRealmless.value = !!(monoRealm.value || getJournal(domainCfg));
    window.monoRealm = monoRealm.value;
    window.hideRealmless = hideRealmless.value;
};

export const reloadUser = async () => {
    if (!CANISTER_ID) return;
    const currentApi = api.value;
    if (!currentApi) return;
    const data = await currentApi.query<User>("user", domain(), []);
    user.value = data || null;
    if (data) {
        data.realms = [...data.realms].reverse();
        window.user = data;
        if (microSecsSince(data.last_activity) > staleActivityMs) {
            lastVisit.value = data.last_activity;
            currentApi.call("update_last_activity");
        } else if (lastVisit.value === BigInt(0)) {
            lastVisit.value = data.last_activity;
        }
    }
};

export const confirmPrincipalChange = async () => {
    if (!CANISTER_ID || !principalId.value) return;
    const pending = await requireApi().query<boolean>("migration_pending");
    if (!pending) return;
    const response = await requireApi().call<{ Err?: string }>(
        "confirm_principal_change",
    );
    if (response?.Err) showToast("error", response.Err);
};

export const loginWithSeed = async (
    seedPhrase: string,
    signUp: boolean,
    inviteCode = "",
) => {
    const normalizedSeed = seedPhrase.trim();
    if (!normalizedSeed) {
        showToast("error", "Seed phrase is required");
        return;
    }
    const seed = await hash(normalizedSeed);
    const identity = Ed25519KeyIdentity.generate(seed);
    if (
        signUp &&
        !isSecureSeedPhrase(normalizedSeed) &&
        !isBip39SeedPhrase(normalizedSeed)
    ) {
        const existingUser = await requireApi().query<User>("user", "", [
            identity.getPrincipal().toString(),
        ]);
        if (
            !existingUser &&
            !window.confirm(
                "Your seed phrase is insecure and will eventually be guessed. A secure seed phrase should be a valid BIP-39 phrase or contain at least 8 symbols such as uppercase and lowercase letters, symbols and digits. Do you want to continue with an insecure seed phrase?",
            )
        ) {
            return;
        }
    }
    localStorage.setItem("IDENTITY", JSON.stringify(identity.toJSON()));
    localStorage.setItem("SEED_PHRASE", "true");
    await instantiateApi();
    await Promise.all([reloadCache(), reloadUser()]);
    navigate(routeAfterLogin(signUp, inviteCode));
};

export const loginWithInternetIdentity = async (
    signUp: boolean,
    inviteCode = "",
) => {
    const client = authClient.value;
    if (!client) {
        showToast("error", "Authentication is still loading. Try again in a moment.", 4);
        return;
    }
    let finished = false;
    const timeout = window.setTimeout(() => {
        if (!finished) {
            reportInternetIdentityError("timeout waiting for Internet Identity response");
        }
    }, 20000);

    const loginOptions: Parameters<AuthClient["login"]>[0] = {
        identityProvider: II_URL,
        maxTimeToLive: BigInt(30 * 24 * 3600000000000),
        onSuccess: async () => {
            finished = true;
            window.clearTimeout(timeout);
            await instantiateApi();
            await Promise.all([reloadCache(), reloadUser()]);
            navigate(routeAfterLogin(signUp, inviteCode));
        },
        onError: (error) => {
            finished = true;
            window.clearTimeout(timeout);
            reportInternetIdentityError(errorText(error));
        },
    };

    try {
        await client.login(loginOptions);
    } catch (error) {
        finished = true;
        window.clearTimeout(timeout);
        reportInternetIdentityError(errorText(error));
    }
};

export const signOut = async () => {
    localStorage.clear();
    sessionStorage.clear();
    await authClient.value?.logout();
    window.location.reload();
};

export const bootstrapAuth = async () => {
    window.lastActivity = new Date();
    window.reloadCache = reloadCache;
    window.reloadUser = reloadUser;
    window.resetUI = () => undefined;
    window.setUI = () => undefined;
    await instantiateApi();
    await Promise.all([reloadCache(), confirmPrincipalChange()]);
    await reloadUser();
    window.setInterval(async () => {
        await reloadUser();
        await reloadCache();
    }, refreshRateMs);
    booting.value = false;
};
