import { HeadBar } from "./common";

export const Privacy = () => (
    <div className="spaced">
        <HeadBar title="PRIVACY" shareLink="privacy" />
        <h2>Data stored by TAGGR</h2>
        <p>
            TAGGR stores account, post, reaction, report, realm, transaction,
            and governance data on the Internet Computer canisters that power
            the service. Public posts, profiles, realms, token balances,
            transactions, governance activity, and moderation records may be
            visible to other users or through public canister interfaces.
        </p>
        <h2>iOS app data</h2>
        <p>
            The iOS app uses native SwiftUI screens and the same production
            TAGGR canister APIs as the website. The MVP iOS app uses no analytics SDK,
            advertising SDK, push notification token collection,
            or separate native account database.
        </p>
        <p>
            Authentication uses Internet Identity. Session state is stored in
            the device keychain.
        </p>
        <h2>Third-party services</h2>
        <p>
            Internet Identity is used for authentication. External links, source
            repositories, OpenChat, and Internet Computer dashboard pages open
            outside the iOS app when they are not TAGGR app routes.
        </p>
        <h2>Token and wallet surfaces</h2>
        <p>
            TAGGR includes token, transaction, ICP, and wallet-related web
            surfaces. In the iOS app these surfaces are read-only for the MVP:
            transfers, minting, auction bidding, wallet mutation, and exchange
            links are hidden or disabled.
        </p>
        <h2>Moderation and support</h2>
        <p>
            User-generated content can be reported from user and post screens.
            Users can block other users from profile menus.
        </p>
        <p>
            For support, moderation questions, or privacy requests, use the HELP
            realm or OpenChat community linked from <a href="#/links">Links</a>.
        </p>
    </div>
);
