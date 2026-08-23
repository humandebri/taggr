import {
    cloudflareTest,
    readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./workers/push-relay/migrations");

export default defineConfig({
    plugins: [
        cloudflareTest({
            wrangler: { configPath: "./workers/push-relay/wrangler.jsonc" },
            miniflare: { bindings: { TEST_MIGRATIONS: migrations } },
        }),
    ],
    test: {
        include: ["workers/push-relay/test/**/*.test.ts"],
    },
});
