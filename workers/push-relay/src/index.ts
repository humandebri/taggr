import { sendPush } from "./apns";
import {
    deliverScheduled,
    handleRequest,
    type RelayDependencies,
} from "./relay";
import type { PushRelayEnv } from "./types";
import { RequestError } from "./validation";

const dependencies: RelayDependencies = {
    canister: async (env, canisterId) => {
        const { pushCanister } = await import("./ic");
        return pushCanister(env, canisterId);
    },
    send: sendPush,
};

export default {
    async fetch(request: Request, env: PushRelayEnv): Promise<Response> {
        try {
            return await handleRequest(request, env, dependencies);
        } catch (error) {
            const status = error instanceof RequestError ? error.status : 500;
            const message =
                error instanceof RequestError
                    ? error.message
                    : "internal server error";
            console.error(
                JSON.stringify({
                    message: "push relay request failed",
                    path: new URL(request.url).pathname,
                    errorType:
                        error instanceof RequestError ? "request" : "internal",
                }),
            );
            return Response.json(
                { error: message },
                { status, headers: { "cache-control": "no-store" } },
            );
        }
    },

    async scheduled(
        controller: ScheduledController,
        env: PushRelayEnv,
        ctx: ExecutionContext,
    ): Promise<void> {
        ctx.waitUntil(
            deliverScheduled(controller, env, dependencies).catch(
                (error: unknown) => {
                    console.error(
                        JSON.stringify({
                            message: "push relay cron failed",
                            error:
                                error instanceof Error
                                    ? error.message
                                    : "unknown error",
                        }),
                    );
                    throw error;
                },
            ),
        );
    },
} satisfies ExportedHandler<PushRelayEnv>;
