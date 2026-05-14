import { activeRealm } from "@/app/state/realms";
import { postDraft, postRealm, submitPost } from "@/app/state/feed";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { Textarea } from "@/app/ui/textarea";

export const Composer = () => {
    const targetRealm = activeRealm.value?.name || postRealm.value;
    return (
        <section className="mx-auto w-full max-w-2xl p-4">
            <Card className="space-y-4 rounded-md p-4">
                <div>
                    <h2 className="text-lg font-semibold">New post</h2>
                    <p className="text-sm text-[hsl(var(--muted-foreground))]">
                        {targetRealm ? `Posting to ${targetRealm}` : "Posting to global feed"}
                    </p>
                </div>
                <Textarea
                    placeholder="What's happening?"
                    value={postDraft.value}
                    onInput={(event) => {
                        postDraft.value = event.currentTarget.value;
                    }}
                />
                <div className="flex justify-end">
                    <Button onClick={() => submitPost(activeRealm.value?.name || "")}>SUBMIT</Button>
                </div>
            </Card>
        </section>
    );
};
