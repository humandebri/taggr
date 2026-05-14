import * as React from "react";
import { currentRealm, foregroundColor, Loading } from "./common";
import { Add, Realm as RealmGlyph } from "./icons";
import { Realm } from "./types";

type RealmMap = { [name: string]: Realm };

export const RealmIcon = ({
    name,
    realm,
    active,
    size = 44,
}: {
    name: string;
    realm?: Realm;
    active?: boolean;
    size?: number;
}) => {
    const label = name.replace(/[^A-Za-z0-9]/g, "").slice(0, 2) || "/";
    const background = realm?.label_color || "#333333";
    const color = foregroundColor(background);
    const style: React.CSSProperties = {
        width: `${size}px`,
        height: `${size}px`,
        minWidth: `${size}px`,
    };

    return (
        <button
            aria-label={`Open realm ${name}`}
            className={`realm_icon_button ${active ? "active_realm_icon" : ""}`}
            data-testid={`realm-rail-${name}`}
            onClick={() => (location.href = `/#/realm/${name}`)}
            style={style}
            title={name}
        >
            {realm?.logo ? (
                <img
                    alt=""
                    className="realm_icon_image"
                    src={`data:image/png;base64, ${realm.logo}`}
                />
            ) : (
                <span
                    className="realm_icon_initials"
                    style={{ background, color }}
                >
                    {label}
                </span>
            )}
        </button>
    );
};

export const RealmRail = ({ route }: { route: string }) => {
    const user = window.user;
    const ids = user?.realms || [];
    const [realms, setRealms] = React.useState<RealmMap>({});
    const [loaded, setLoaded] = React.useState(false);

    React.useEffect(() => {
        if (!user || window.monoRealm || ids.length == 0) return;

        let mounted = true;
        window.api.query<Realm[]>("realms", ids).then((data) => {
            if (!mounted) return;
            const mapped: RealmMap = {};
            (data || []).forEach((realm, index) => {
                mapped[ids[index]] = realm;
            });
            setRealms(mapped);
            setLoaded(true);
        });

        return () => {
            mounted = false;
        };
    }, [ids.join("|"), user?.id]);

    React.useEffect(() => {
        if (!user || window.monoRealm || ids.length == 0) return;

        document.body.classList.add("with_realm_rail");
        return () => document.body.classList.remove("with_realm_rail");
    }, [ids.length, user?.id]);

    if (!user || window.monoRealm || ids.length == 0) return null;

    const activeRealm = currentRealm();
    return (
        <nav
            aria-label="Realms"
            className="realm_rail"
            data-testid="realm-rail"
        >
            <button
                aria-label="Home"
                className={`realm_icon_button ${!activeRealm ? "active_realm_icon" : ""}`}
                onClick={() => (location.href = "/#/home")}
                title="Home"
            >
                <RealmGlyph />
            </button>
            <div className="realm_rail_separator" />
            <div className="realm_rail_realms">
                {!loaded && <Loading />}
                {loaded &&
                    ids.map((id) => (
                        <RealmIcon
                            key={`${route}-${id}`}
                            active={activeRealm == id}
                            name={id}
                            realm={realms[id]}
                        />
                    ))}
            </div>
            <div className="realm_rail_separator" />
            <a
                aria-label="Explore realms"
                className="realm_icon_button realm_rail_link"
                href="/#/realms"
                title="Explore realms"
            >
                <RealmGlyph />
            </a>
            <a
                aria-label="Create realm"
                className="realm_icon_button realm_rail_link"
                href="/#/realms/create"
                title="Create realm"
            >
                <Add />
            </a>
        </nav>
    );
};
