import { Infinity, KeyRound, Ticket } from "lucide-react";
import {
    loginWithInternetIdentity,
    loginWithSeed,
    principalId,
    requireApi,
} from "@/app/state/auth";
import { navigate } from "@/app/state/route";
import { showToast } from "@/app/state/ui";
import { signal } from "@preact/signals";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { Input } from "@/app/ui/input";

const seedPhrase = signal("");
const seedConfirmation = signal("");
const selected = signal<"none" | "seed">("none");

const handleInvite = async () => {
    const code = window.prompt("Enter invite code")?.trim().toLowerCase() || "";
    if (!code) {
        showToast("error", "Invite code is required");
        return;
    }
    if (!(await requireApi().query<boolean>("check_invite", code))) {
        showToast("error", "Invalid invite");
        return;
    }
    navigate(`welcome/${code}`);
};

export const AuthPage = ({
    signUp = false,
    inviteCode = "",
}: {
    signUp?: boolean;
    inviteCode?: string;
}) => (
    <section className="mx-auto flex min-h-[calc(100vh-3.5rem)] w-full max-w-md items-center p-4">
        <Card className="w-full space-y-5 rounded-md p-5">
            <div>
                <h2 className="text-xl font-semibold">{signUp ? "Sign-up" : "Sign-in"}</h2>
                <p className="mt-1 text-sm text-[hsl(var(--muted-foreground))]">
                    Choose an authentication method.
                </p>
            </div>
            {selected.value === "seed" ? (
                <div className="space-y-3">
                    <Input
                        type="password"
                        placeholder="Enter your seed phrase..."
                        value={seedPhrase.value}
                        onInput={(event) => {
                            seedPhrase.value = event.currentTarget.value;
                        }}
                    />
                    {signUp && (
                        <Input
                            type="password"
                            placeholder="Repeat your seed phrase..."
                            value={seedConfirmation.value}
                            onInput={(event) => {
                                seedConfirmation.value = event.currentTarget.value;
                            }}
                        />
                    )}
                    <div className="flex gap-2">
                        {principalId.value && (
                            <Button variant="secondary" onClick={() => window.location.reload()}>
                                CANCEL
                            </Button>
                        )}
                        <Button
                            className="flex-1"
                            onClick={() => {
                                if (signUp && seedPhrase.value !== seedConfirmation.value) {
                                    showToast("error", "Seed phrases do not match.");
                                    return;
                                }
                                loginWithSeed(seedPhrase.value, signUp, inviteCode);
                            }}
                        >
                            CONTINUE
                        </Button>
                    </div>
                </div>
            ) : (
                <div className="space-y-3">
                    {signUp && (
                        <Button variant="outline" className="w-full justify-start" onClick={handleInvite}>
                            <Ticket className="h-4 w-4" /> Invite
                        </Button>
                    )}
                    <Button className="w-full justify-start" onClick={() => loginWithInternetIdentity(signUp, inviteCode)}>
                        <Infinity className="h-4 w-4" /> Internet Identity
                    </Button>
                    <Button variant="secondary" className="w-full justify-start" onClick={() => (selected.value = "seed")}>
                        <KeyRound className="h-4 w-4" /> Seed Phrase
                    </Button>
                </div>
            )}
        </Card>
    </section>
);
