import { Dashboard } from "@/dashboard";
import {
    Delegate,
    DELEGATION_DOMAIN,
    DELEGATION_PRINCIPAL,
} from "@/delegation";
import { Diff } from "@/diff";
import { Distribution } from "@/distribution";
import { Domains } from "@/domains";
import { Feed } from "@/feed";
import { HeadBar, expandMeta, loadFeed } from "@/common";
import { Inbox } from "@/inbox";
import { Invites } from "@/invites";
import { Journal } from "@/journal";
import { LinksPage } from "@/links";
import { PostSubmissionForm } from "@/new";
import { PostFeed } from "@/post_feed";
import { Proposals } from "@/proposals";
import { RealmForm } from "@/realms";
import { Search } from "@/search";
import { Thread } from "@/thread";
import { Tokens, TransactionView, TransactionsView } from "@/tokens";
import { Whitepaper } from "@/whitepaper";
import { route, Route } from "@/app/state/route";

const legacyRouteNames = [
    "bookmarks",
    "dashboard",
    "delegate",
    "diff",
    "distribution",
    "domains",
    "edit",
    "feed",
    "inbox",
    "invites",
    "journal",
    "links",
    "proposals",
    "reposts",
    "search",
    "stats",
    "thread",
    "tokens",
    "transaction",
    "transactions",
    "whitepaper",
];

export const isLegacyRoute = (current: Route) =>
    legacyRouteNames.includes(current.name) ||
    (current.name === "realm" && current.params[1] === "edit");

export const requiresLegacyPrincipal = (current: Route) =>
    ["bookmarks", "edit", "inbox", "invites"].includes(current.name) ||
    (current.name === "realm" && current.params[1] === "edit");

export const requiresLegacyUser = (current: Route) =>
    current.name === "delegate";

export const LegacyRoute = () => {
    const current = route.value;
    const [param = "", param2 = ""] = current.params;
    if (current.name === "bookmarks") {
        return (
            <PostFeed
                useList={true}
                title={<HeadBar title="BOOKMARKS" shareLink="bookmarks" />}
                includeComments={true}
                feedLoader={async () => await loadFeed(window.user.bookmarks)}
            />
        );
    }
    if (current.name === "dashboard" || current.name === "stats") {
        return <Dashboard />;
    }
    if (current.name === "delegate") {
        if (param) localStorage.setItem(DELEGATION_DOMAIN, param);
        if (param2) localStorage.setItem(DELEGATION_PRINCIPAL, param2);
        return <Delegate />;
    }
    if (current.name === "diff") return <Diff from={param} to={param2} />;
    if (current.name === "distribution") return <Distribution />;
    if (current.name === "domains") return <Domains />;
    if (current.name === "edit") {
        return <PostSubmissionForm id={parseInt(param)} />;
    }
    if (current.name === "feed") {
        return <Feed params={param.split(/\+/).map(decodeURIComponent)} />;
    }
    if (current.name === "inbox") return <Inbox />;
    if (current.name === "invites") return <Invites />;
    if (current.name === "journal") return <Journal handle={param} />;
    if (current.name === "links") return <LinksPage />;
    if (current.name === "proposals") return <Proposals />;
    if (current.name === "realm" && current.params[1] === "edit") {
        return <RealmForm existingName={param.toUpperCase()} />;
    }
    if (current.name === "reposts") {
        const id = parseInt(param);
        return (
            <PostFeed
                title={
                    <HeadBar
                        title={
                            <>
                                REPOSTS OF <a href={`#/post/${id}`}>#{id}</a>
                            </>
                        }
                        shareLink={`/reposts/${id}`}
                    />
                }
                feedLoader={async () => {
                    const posts = await loadFeed([id]);
                    if (posts && posts.length > 0) {
                        return await loadFeed(expandMeta(posts[0]).reposts);
                    }
                    return [];
                }}
            />
        );
    }
    if (current.name === "search") return <Search initQuery={param} />;
    if (current.name === "thread") return <Thread id={parseInt(param)} />;
    if (current.name === "tokens") return <Tokens />;
    if (current.name === "transaction") {
        return <TransactionView id={parseInt(param)} />;
    }
    if (current.name === "transactions") {
        return <TransactionsView icrcAccount={param} prime={true} />;
    }
    if (current.name === "whitepaper") return <Whitepaper />;
    return null;
};
