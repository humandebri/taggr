import { Edit, Share2, Users } from "lucide-react";
import { activeRealm, toggleRealmMembership } from "@/app/state/realms";
import { user } from "@/app/state/auth";
import { FeedView } from "@/app/feed/FeedView";
import { RealmIcon } from "@/app/components/RealmIcon";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { Badge } from "@/app/ui/badge";
import { navigate } from "@/app/state/route";
import { shareUrl } from "@/app/lib/domain";

export const RealmHome = () => {
    const current = activeRealm.value;
    if (!current) return <div className="p-6 text-sm text-[hsl(var(--muted-foreground))]">Realm not found.</div>;
    const { name, realm } = current;
    const joined = !!user.value?.realms.includes(name);
    const controller = !!user.value && realm.controllers.includes(user.value.id);
    return (
        <div className="grid min-h-[calc(100vh-3.5rem)] grid-cols-1 xl:grid-cols-[1fr_320px]">
            <main className="min-w-0">
                <section className="border-b border-[hsl(var(--border))] p-4">
                    <div className="mx-auto flex max-w-5xl flex-col gap-4 md:flex-row md:items-center">
                        <RealmIcon name={name} realm={realm} active size={72} />
                        <div className="min-w-0 flex-1">
                            <h2 className="truncate text-2xl font-semibold">{name}</h2>
                            <div className="mt-2 flex flex-wrap gap-2">
                                <Badge>{realm.num_members} members</Badge>
                                <Badge>{realm.num_posts} posts</Badge>
                                {realm.adult_content && <Badge>adult</Badge>}
                            </div>
                        </div>
                        <div className="flex flex-wrap gap-2">
                            {controller && (
                                <Button variant="secondary" onClick={() => navigate(`realm/${name}/edit`)}>
                                    <Edit className="h-4 w-4" /> EDIT
                                </Button>
                            )}
                            {user.value && (
                                <Button variant={joined ? "outline" : "default"} onClick={() => toggleRealmMembership(name)}>
                                    <Users className="h-4 w-4" /> {joined ? "LEAVE" : "JOIN"}
                                </Button>
                            )}
                            <Button variant="ghost" onClick={() => shareUrl(`#/realm/${name}`)}>
                                <Share2 className="h-4 w-4" /> SHARE
                            </Button>
                        </div>
                    </div>
                </section>
                <FeedView />
            </main>
            <aside className="border-t border-[hsl(var(--border))] p-4 xl:border-l xl:border-t-0">
                <Card className="space-y-4 rounded-md p-4">
                    <div>
                        <h3 className="text-sm font-semibold uppercase tracking-wide text-[hsl(var(--muted-foreground))]">About</h3>
                        <p className="mt-2 whitespace-pre-wrap text-sm leading-6">{realm.description}</p>
                    </div>
                    <div className="grid grid-cols-2 gap-3 text-sm">
                        <div>
                            <div className="text-[hsl(var(--muted-foreground))]">Cleanup</div>
                            <div>{realm.cleanup_penalty} credits</div>
                        </div>
                        <div>
                            <div className="text-[hsl(var(--muted-foreground))]">Max downvotes</div>
                            <div>{realm.max_downvotes}</div>
                        </div>
                    </div>
                </Card>
            </aside>
        </div>
    );
};
