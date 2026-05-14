import { render } from "preact";
import "./app/styles.css";
import { App } from "@/app/App";
import { bootstrapAuth } from "@/app/state/auth";
import { installRouteListener } from "@/app/state/route";
import { loadRouteData } from "@/app/router";

export { instantiateApi } from "@/app/state/auth";

const { hash, pathname } = location;

if (!hash && pathname !== "/") {
    location.href = `#${pathname}`;
}

const root = document.getElementById("stack");
document.getElementById("logo_container")?.remove();

if (!root) throw new Error("TAGGR root is missing");

render(<App />, root);

bootstrapAuth()
    .then(async () => {
        installRouteListener(loadRouteData);
        await loadRouteData();
    })
    .catch((error: unknown) => {
        console.error(error);
    });
