import { signal } from "@preact/signals";
import { UserFilter } from "@/types";
import { requireApi, reloadUser, user } from "@/app/state/auth";
import { showToast } from "@/app/state/ui";

export type IcpInvoice = {
    paid: boolean;
    e8s: BigInt;
    account: number[];
};

export const profileName = signal("");
export const profileAbout = signal("");
export const profileReady = signal(false);
export const icpInvoice = signal<IcpInvoice | null>(null);
export const invoiceLoading = signal(false);

const hex = (arr: number[]) =>
    Array.from(arr, (byte) =>
        ("0" + (byte & 0xff).toString(16)).slice(-2),
    ).join("");

export const invoiceAmount = () =>
    icpInvoice.value ? (Number(icpInvoice.value.e8s) / 1e8).toString() : "";

export const invoiceAccount = () =>
    icpInvoice.value ? hex(icpInvoice.value.account) : "";

const defaultFilter = (): UserFilter => ({
    safe: false,
    age_days: 0,
    balance: 0,
    num_followers: 0,
});

export const syncProfileForm = () => {
    profileName.value = user.value?.name || "";
    profileAbout.value = user.value?.about || "";
    profileReady.value = true;
};

export const createOrUpdateUser = async (invite = "") => {
    const name = profileName.value.trim();
    const registrationFlow = !user.value;
    let registrationRealmId: string | undefined;
    if (!name) {
        showToast("error", "User name is required");
        return;
    }
    if (registrationFlow) {
        const create = await requireApi().call<{ Err?: string; Ok?: string }>(
            "create_user",
            name,
            invite,
        );
        if (create?.Err) {
            showToast("error", create.Err);
            return;
        }
        registrationRealmId = create?.Ok;
    }
    const nameChange = !registrationFlow && user.value?.name !== name;
    if (
        nameChange &&
        !window.confirm(
            "A name change incurs costs. The old name will still route to your profile. Continue?",
        )
    ) {
        return;
    }
    const response = await requireApi().call<{ Err?: string }>(
        "update_user",
        nameChange ? name : "",
        profileAbout.value,
        user.value?.controllers || [],
        user.value?.filters.noise || defaultFilter(),
        user.value?.governance ?? true,
        user.value?.mode || "Credits",
        user.value?.show_posts_in_realms ?? true,
    );
    if (response?.Err) {
        showToast("error", response.Err);
        return;
    }
    const settingsResponse = await requireApi().call<{ Err?: string }>(
        "update_user_settings",
        user.value?.settings || {},
    );
    if (settingsResponse?.Err) {
        showToast("error", settingsResponse.Err);
        return;
    }
    await reloadUser();
    window.location.hash = registrationRealmId
        ? `#/realm/${registrationRealmId}`
        : "#/home";
};

export const mintCreditsWithIcp = async () => {
    invoiceLoading.value = true;
    try {
        const result = await requireApi().call<{
            Err?: string;
            Ok?: IcpInvoice;
        }>("mint_credits_with_icp", 0);
        if (result?.Err) {
            showToast("error", result.Err);
            return;
        }
        icpInvoice.value = result?.Ok || null;
    } finally {
        invoiceLoading.value = false;
    }
};
