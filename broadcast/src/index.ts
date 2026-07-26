import { registerDevice, unregisterDevice } from "./devices";
import { getDownloadStats, redirectToMacDownload } from "./downloads";
import { getFeed, publishAdminItem } from "./feed";
import { errorResponse, json } from "./http";
import { consumePushBatch } from "./push";
import { runScheduled } from "./scheduled";
import type { Env, PushJob } from "./types";
import {
  PRIMARY_ACCOUNTS,
  PRIMARY_DAILY_LIMIT,
  ROTATING_ACCOUNTS,
  ROTATING_DAILY_LIMIT,
} from "./x-api";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return json({
          status: "ok",
          delivery: "server-curated",
          xCredentialsInClient: false,
          originalPostsOnly: false,
          postTypes: {
            original: true,
            quote: true,
            reply: false,
            repost: false,
          },
          collection: {
            primary: {
              accounts: PRIMARY_ACCOUNTS.map((account) => account.username),
              dailyLimit: PRIMARY_DAILY_LIMIT,
            },
            rotating: {
              accounts: ROTATING_ACCOUNTS.map((account) => account.username),
              dailyLimit: ROTATING_DAILY_LIMIT,
            },
          },
        });
      }
      if (request.method === "GET" && url.pathname === "/v1/ai-feed") {
        return await getFeed(env);
      }
      if (request.method === "GET" && url.pathname === "/v1/downloads/macos") {
        return await redirectToMacDownload(env);
      }
      if (request.method === "GET" && url.pathname === "/v1/downloads/stats") {
        return await getDownloadStats(env);
      }
      if (request.method === "POST" && url.pathname === "/v1/devices/register") {
        return await registerDevice(request, env);
      }
      const deviceMatch = url.pathname.match(/^\/v1\/devices\/([A-Za-z0-9_-]{16,128})$/);
      if (request.method === "DELETE" && deviceMatch?.[1]) {
        return await unregisterDevice(request, env, deviceMatch[1]);
      }
      if (request.method === "POST" && url.pathname === "/v1/admin/feed/items") {
        return await publishAdminItem(request, env);
      }
      return json({ detail: "not found" }, { status: 404 });
    } catch (error) {
      return errorResponse(error);
    }
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    await runScheduled(controller, env);
  },

  async queue(batch: MessageBatch<PushJob>, env: Env): Promise<void> {
    await consumePushBatch(batch, env);
  },
} satisfies ExportedHandler<Env, PushJob>;
