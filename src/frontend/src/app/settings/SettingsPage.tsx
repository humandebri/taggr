import { principalId, user } from "@/app/state/auth";
import {
    createOrUpdateUser,
    icpInvoice,
    invoiceAccount,
    invoiceAmount,
    invoiceLoading,
    mintCreditsWithIcp,
    profileAbout,
    profileName,
    syncProfileForm,
} from "@/app/state/settings";
import { isIOSApp } from "@/platform/ios/webview";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { Input } from "@/app/ui/input";

const copyText = async (value: string) => {
    await navigator.clipboard.writeText(value);
};

export const SettingsPage = ({ invite = "" }: { invite?: string }) => {
    if (user.value && profileName.value === "") syncProfileForm();
    return (
        <section className="mx-auto w-full max-w-2xl p-4">
            <Card className="space-y-5 rounded-md p-5">
                <div>
                    <h2 className="text-xl font-semibold">{user.value ? "Settings" : "Create user"}</h2>
                    <p className="mt-1 break-all text-sm text-[hsl(var(--muted-foreground))]">{principalId.value}</p>
                </div>
                {!user.value && !isIOSApp() && !icpInvoice.value && (
                    <Button
                        variant="secondary"
                        disabled={invoiceLoading.value}
                        onClick={mintCreditsWithIcp}
                    >
                        {invoiceLoading.value
                            ? "CHECKING..."
                            : "MINT CREDITS WITH ICP"}
                    </Button>
                )}
                {!user.value && isIOSApp() && (
                    <p className="rounded-md border border-[hsl(var(--border))] p-3 text-sm text-[hsl(var(--muted-foreground))]">
                        ICP credit minting is unavailable in the iOS app. Use an
                        invite or the web app to activate a new account.
                    </p>
                )}
                {!user.value && icpInvoice.value && !icpInvoice.value.paid && (
                    <div className="space-y-3 rounded-md border border-[hsl(var(--border))] p-3 text-sm">
                        <p>Transfer at least {invoiceAmount()} ICP to account:</p>
                        <button
                            className="break-all rounded bg-[hsl(var(--secondary))] p-2 text-left font-mono text-xs"
                            data-testid="account-to-transfer-to"
                            onClick={() => copyText(invoiceAccount())}
                        >
                            {invoiceAccount()}
                        </button>
                        <div className="flex gap-2">
                            <Button
                                variant="secondary"
                                disabled={invoiceLoading.value}
                                onClick={mintCreditsWithIcp}
                            >
                                CHECK BALANCE
                            </Button>
                            <Button
                                variant="ghost"
                                onClick={() => {
                                    icpInvoice.value = null;
                                }}
                            >
                                CHANGE PAYMENT
                            </Button>
                        </div>
                    </div>
                )}
                {!user.value && icpInvoice.value?.paid && (
                    <div className="rounded-md border border-emerald-500/40 bg-emerald-950/40 p-3 text-sm">
                        Credits minted. You can create a user account now.
                    </div>
                )}
                <div className="space-y-2">
                    <label className="text-sm font-medium">User name</label>
                    <Input
                        placeholder="alphanumeric"
                        value={profileName.value}
                        onInput={(event) => {
                            profileName.value = event.currentTarget.value;
                        }}
                    />
                </div>
                <div className="space-y-2">
                    <label className="text-sm font-medium">About you</label>
                    <Input
                        placeholder="tell us what we should know about you"
                        value={profileAbout.value}
                        onInput={(event) => {
                            profileAbout.value = event.currentTarget.value;
                        }}
                    />
                </div>
                <div className="flex justify-end">
                    <Button
                        disabled={!user.value && !invite && !icpInvoice.value?.paid}
                        onClick={() => createOrUpdateUser(invite)}
                    >
                        {user.value ? "SAVE" : "CREATE USER"}
                    </Button>
                </div>
            </Card>
        </section>
    );
};

export const WelcomePage = ({ invite = "" }: { invite?: string }) => (
    <SettingsPage invite={invite} />
);
