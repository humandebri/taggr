import { FeedMode, feedFiltered, feedLoading, feedMode, feedPosts, loadFeed } from "@/app/state/feed";
import { activeRealm } from "@/app/state/realms";
import { user } from "@/app/state/auth";
import { Button } from "@/app/ui/button";
import { Tabs, TabsList, TabsTrigger } from "@/app/ui/tabs";
import { PostCard } from "@/app/components/PostCard";

const feedTabs = () => {
    const tabs = ["NEW", "HOT"];
    if (!activeRealm.value && user.value) tabs.push("FOR_ME", "REALMS");
    return tabs;
};

const isFeedMode = (value: string): value is FeedMode =>
    ["NEW", "HOT", "REALMS", "FOR_ME"].includes(value);

export const FeedView = () => (
    <section className="mx-auto flex w-full max-w-3xl flex-col gap-4 p-4">
        <Tabs
            value={feedMode.value}
            onValueChange={(value) => {
                if (isFeedMode(value)) {
                    feedMode.value = value;
                }
                loadFeed(activeRealm.value?.name || "");
            }}
        >
            <TabsList>
                {feedTabs().map((tab) => (
                    <TabsTrigger key={tab} value={tab} data-testid={`tab-${tab}`}>
                        {tab}
                    </TabsTrigger>
                ))}
            </TabsList>
        </Tabs>
        {feedMode.value === "NEW" && user.value && (
            <label className="flex items-center gap-2 text-sm text-[hsl(var(--muted-foreground))]">
                <input
                    type="checkbox"
                    checked={feedFiltered.value}
                    onChange={(event) => {
                        feedFiltered.value = event.currentTarget.checked;
                        loadFeed(activeRealm.value?.name || "");
                    }}
                />
                Apply user filters
            </label>
        )}
        {feedPosts.value.map((post) => (
            <PostCard key={post.id} post={post} />
        ))}
        {feedLoading.value && <div className="py-8 text-center text-sm text-[hsl(var(--muted-foreground))]">Loading...</div>}
        {!feedLoading.value && feedPosts.value.length > 0 && (
            <Button variant="secondary" onClick={() => loadFeed(activeRealm.value?.name || "", false)}>
                MORE
            </Button>
        )}
    </section>
);
