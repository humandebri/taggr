import { commentDraft, focusedPost, submitComment } from "@/app/state/feed";
import { PostCard } from "@/app/components/PostCard";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { Textarea } from "@/app/ui/textarea";
import { user } from "@/app/state/auth";

export const PostPage = () => {
    const post = focusedPost.value;
    if (!post) return <div className="p-6 text-sm text-[hsl(var(--muted-foreground))]">Post not found.</div>;
    return (
        <section className="mx-auto flex w-full max-w-3xl flex-col gap-4 p-4">
            <PostCard post={post} compact />
            {user.value && (
                <Card className="space-y-3 rounded-md p-4">
                    <Textarea
                        placeholder="Reply here..."
                        value={commentDraft.value}
                        onInput={(event) => {
                            commentDraft.value = event.currentTarget.value;
                        }}
                    />
                    <div className="flex justify-end">
                        <Button onClick={() => submitComment(post)}>SUBMIT</Button>
                    </div>
                </Card>
            )}
        </section>
    );
};
