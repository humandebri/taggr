import { signal } from "@preact/signals";
import { User } from "@/types";
import { requireApi, user } from "@/app/state/auth";
import { domain } from "@/app/lib/domain";
import { Badge } from "@/app/ui/badge";
import { Card } from "@/app/ui/card";

export const viewedProfile = signal<User | null>(null);

export const loadProfile = async (handle: string) => {
    viewedProfile.value =
        (await requireApi().query<User>("user", domain(), [handle])) || null;
};

export const ProfilePage = () => {
    const profile = viewedProfile.value || user.value;
    if (!profile) return <div className="p-6 text-sm text-[hsl(var(--muted-foreground))]">User not found.</div>;
    return (
        <section className="mx-auto w-full max-w-3xl p-4">
            <Card className="rounded-md p-5">
                <div className="flex items-start gap-4">
                    <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-[hsl(var(--secondary))] text-lg font-bold">
                        {profile.name.slice(0, 2).toUpperCase()}
                    </div>
                    <div className="min-w-0 flex-1">
                        <h2 className="text-2xl font-semibold">{profile.name}</h2>
                        <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-[hsl(var(--muted-foreground))]">
                            {profile.about || "No profile text."}
                        </p>
                        <div className="mt-4 flex flex-wrap gap-2">
                            <Badge>POSTS {profile.num_posts}</Badge>
                            <Badge>JOINED REALMS {profile.realms.length}</Badge>
                            <Badge>BALANCE {profile.balance.toLocaleString()}</Badge>
                        </div>
                    </div>
                </div>
            </Card>
        </section>
    );
};
