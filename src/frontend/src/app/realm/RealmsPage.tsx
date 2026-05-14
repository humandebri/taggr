import { createRealm, realmFormColor, realmFormDescription, realmFormName, realmsIndex } from "@/app/state/realms";
import { route, navigate } from "@/app/state/route";
import { RealmIcon } from "@/app/components/RealmIcon";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { Input } from "@/app/ui/input";
import { Textarea } from "@/app/ui/textarea";

export const RealmsPage = () => {
    if (route.value.params[0] === "create") return <RealmCreatePage />;
    return (
        <section className="mx-auto grid w-full max-w-5xl grid-cols-1 gap-4 p-4 md:grid-cols-2">
            <div className="md:col-span-2 flex items-center justify-between">
                <div>
                    <h2 className="text-xl font-semibold">Explore realms</h2>
                    <p className="text-sm text-[hsl(var(--muted-foreground))]">Find public server spaces.</p>
                </div>
                <Button onClick={() => navigate("realms/create")}>CREATE</Button>
            </div>
            {realmsIndex.value.map(({ name, realm }) => (
                <button key={name} className="text-left" onClick={() => navigate(`realm/${name}`)}>
                    <Card className="flex gap-4 rounded-md p-4 transition-colors hover:bg-[hsl(var(--secondary))]">
                        <RealmIcon name={name} realm={realm} />
                        <div className="min-w-0">
                            <h3 className="truncate font-semibold">{name}</h3>
                            <p className="mt-1 line-clamp-2 text-sm text-[hsl(var(--muted-foreground))]">{realm.description}</p>
                            <p className="mt-2 text-xs text-[hsl(var(--muted-foreground))]">
                                {realm.num_members} members / {realm.num_posts} posts
                            </p>
                        </div>
                    </Card>
                </button>
            ))}
        </section>
    );
};

export const RealmCreatePage = () => (
    <section className="mx-auto w-full max-w-2xl p-4">
        <Card className="space-y-5 rounded-md p-5">
            <div>
                <h2 className="text-xl font-semibold">Create realm</h2>
                <p className="mt-1 text-sm text-[hsl(var(--muted-foreground))]">Realm becomes a server in the new navigation.</p>
            </div>
            <div className="space-y-2">
                <label className="text-sm font-medium">Realm name</label>
                <Input
                    placeholder="alphanumeric"
                    value={realmFormName.value}
                    onInput={(event) => {
                        realmFormName.value = event.currentTarget.value.toUpperCase();
                    }}
                />
            </div>
            <div className="space-y-2">
                <label className="text-sm font-medium">Label color</label>
                <Input
                    type="color"
                    value={realmFormColor.value}
                    onInput={(event) => {
                        realmFormColor.value = event.currentTarget.value;
                    }}
                />
            </div>
            <div className="space-y-2">
                <label className="text-sm font-medium">Description</label>
                <Textarea
                    data-testid="realm-textarea"
                    value={realmFormDescription.value}
                    onInput={(event) => {
                        realmFormDescription.value = event.currentTarget.value;
                    }}
                />
            </div>
            <div className="flex justify-end">
                <Button onClick={createRealm}>CREATE</Button>
            </div>
        </Card>
    </section>
);
