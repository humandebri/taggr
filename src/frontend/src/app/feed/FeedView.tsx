import {
    FeedMode,
    feedFiltered,
    feedLoading,
    feedMode,
    feedPosts,
    loadFeed,
} from "@/app/state/feed";
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

export const FeedView = () => {
    const tabs = feedTabs();
    return (
        <section className="mx-auto flex w-full max-w-3xl flex-col gap-3 p-3 sm:gap-4 sm:p-4">
            <Tabs
                value={feedMode.value}
                onValueChange={(value) => {
                    if (isFeedMode(value)) {
                        feedMode.value = value;
                    }
                    loadFeed(activeRealm.value?.name || "");
                }}
            >
                <TabsList
                    className="grid w-full"
                    style={{
                        gridTemplateColumns: `repeat(${tabs.length}, minmax(0, 1fr))`,
                    }}
                >
                    {tabs.map((tab) => (
                        <TabsTrigger
                            className="px-2 text-xs sm:px-3 sm:text-sm"
                            key={tab}
                            value={tab}
                            data-testid={`tab-${tab}`}
                        >
                            {tab}
                        </TabsTrigger>
                    ))}
                </TabsList>
            </Tabs>
            {feedMode.value === "NEW" && user.value && (
                <label className="flex items-center gap-2 px-1 text-sm text-[hsl(var(--muted-foreground))]">
                    <input
                        className="accent-[hsl(var(--primary))]"
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
            {feedLoading.value && (
                <div className="py-8 text-center text-sm text-[hsl(var(--muted-foreground))]">
                    Loading...
                </div>
            )}
            {!feedLoading.value && feedPosts.value.length > 0 && (
                <Button
                    variant="secondary"
                    onClick={() =>
                        loadFeed(activeRealm.value?.name || "", false)
                    }
                >
                    MORE
                </Button>
            )}
        </section>
    );
};
