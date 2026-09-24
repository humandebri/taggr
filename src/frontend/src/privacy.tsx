import { HeadBar } from "./common";

export const PrivacyPage = ({}) => {
    return (
        <div className="spaced">
            <HeadBar title="PRIVACY" shareLink="privacy" />
            <h2>Privacy policy</h2>
            <p>
                TAGGR is a decentralized social network. Content posted to TAGGR
                is stored on-chain and can be publicly visible.
            </p>
            <p>
                Production URL:{" "}
                <a href="https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/privacy">
                    https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/privacy
                </a>
            </p>
            <h2>Data stored by TAGGR</h2>
            <ul>
                <li>Posts, comments, reactions, reports, and profile data.</li>
                <li>
                    Public identifiers such as Internet Identity principals.
                </li>
                <li>
                    Token and wallet surfaces expose public ledger data and
                    wallet actions initiated by the signed-in user.
                </li>
            </ul>
            <h2>iOS app data</h2>
            <p>
                The iOS app stores the current TAGGR session locally. The app
                includes no analytics SDK and no advertising SDK. It does not
                perform push notification token collection.
            </p>
            <h2>Third-party services</h2>
            <p>
                Internet Identity is used for authentication. Token metadata,
                ledger interactions, and external community links can open
                third-party services.
            </p>
            <h2>Token and wallet surfaces</h2>
            <p>
                On iOS, Account supports ICP transfers, reward withdrawals, and
                ICP credit minting. Each wallet operation is initiated by the
                signed-in user.
            </p>
            <h2>Support</h2>
            <p>
                For support, use the <a href="#/realm/HELP">HELP</a> realm or
                the OpenChat Community linked from <a href="#/links">Links</a>.
            </p>
        </div>
    );
};
