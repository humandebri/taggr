import { MessageCircle, Star } from "lucide-react";
import { Post } from "@/types";
import { timeAgo } from "@/app/lib/format";
import { Badge } from "@/app/ui/badge";
import { Button } from "@/app/ui/button";
import { Card } from "@/app/ui/card";
import { navigate } from "@/app/state/route";

const renderBody = (body: string) =>
    body
        .split(/\n{2,}/)
        .map((paragraph) => <p key={paragraph.slice(0, 32)}>{paragraph}</p>);

export const PostCard = ({
    post,
    compact = false,
}: {
    post: Post;
    compact?: boolean;
}) => (
    <article className="feed_item">
        <Card className="rounded-md p-3 sm:p-4">
            <div className="mb-3 flex items-start gap-2.5 sm:gap-3">
                <button
                    className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[hsl(var(--secondary))] text-sm font-bold sm:h-10 sm:w-10"
                    onClick={() => navigate(`user/${post.meta.author_name}`)}
                >
                    {post.meta.author_name.slice(0, 2).toUpperCase()}
                </button>
                <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2 text-sm">
                        <button
                            className="font-semibold hover:underline"
                            onClick={() =>
                                navigate(`user/${post.meta.author_name}`)
                            }
                        >
                            {post.meta.author_name}
                        </button>
                        <span className="text-[hsl(var(--muted-foreground))]">
                            {timeAgo(post.timestamp)} ago
                        </span>
                        {post.realm && (
                            <button
                                onClick={() => navigate(`realm/${post.realm}`)}
                            >
                                <Badge className="realm_span realm_tag">
                                    {post.realm}
                                </Badge>
                            </button>
                        )}
                    </div>
                    <button
                        className="mt-2 block w-full text-left"
                        onClick={() => !compact && navigate(`post/${post.id}`)}
                    >
                        <div className="post-body whitespace-pre-wrap text-[0.9375rem] leading-6 text-[hsl(var(--foreground))]">
                            {renderBody(post.effBody || post.body)}
                        </div>
                    </button>
                </div>
            </div>
            <div className="flex items-center gap-1 border-t border-[hsl(var(--border))] pt-2 text-[hsl(var(--muted-foreground))] sm:gap-2 sm:pt-3">
                <Button
                    className="min-w-12"
                    variant="ghost"
                    size="sm"
                    onClick={() => navigate(`post/${post.id}`)}
                >
                    <MessageCircle className="h-4 w-4" />
                    {post.children.length}
                </Button>
                <Button
                    className="min-w-12"
                    variant="ghost"
                    size="sm"
                    data-testid="reaction-picker"
                >
                    <Star className="h-4 w-4" />
                    {Object.values(post.reactions).flat().length}
                </Button>
                <span className="ml-auto text-xs">#{post.id}</span>
            </div>
        </Card>
    </article>
);
