import type { Env } from "./types";
import { snapshotDownloadHistory } from "./downloads";
import { snapshotStarHistory } from "./stars";
import { enqueueDueDailyDigests } from "./push";
import { syncPrimaryPosts, syncRotatingPosts } from "./x-api";

export async function runScheduled(
  controller: ScheduledController,
  env: Env,
): Promise<void> {
  const executionKey = `${controller.cron}:${controller.scheduledTime}`;
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO cron_runs (execution_key, created_at) VALUES (?, ?)",
  )
    .bind(executionKey, new Date(controller.scheduledTime).toISOString())
    .run();
  if (inserted.meta.changes === 0) {
    controller.noRetry();
    return;
  }

  if (controller.cron === "*/10 * * * *") {
    try {
      const result = await syncPrimaryPosts(env, new Date(controller.scheduledTime));
      console.log("Primary X sync complete", result);
    } catch (error) {
      console.error("Primary X sync failed", safeError(error));
    }
  } else if (controller.cron === "0 * * * *") {
    try {
      const result = await syncRotatingPosts(env, new Date(controller.scheduledTime));
      console.log("Rotating X discovery complete", result);
    } catch (error) {
      console.error("Rotating X discovery failed", safeError(error));
    }
    const queued = await enqueueDueDailyDigests(env, new Date(controller.scheduledTime));
    console.log("Daily digest scheduling complete", { queued });
    try {
      await snapshotDownloadHistory(env, new Date(controller.scheduledTime));
    } catch (error) {
      console.error("Download history snapshot failed", safeError(error));
    }
    try {
      await snapshotStarHistory(env, new Date(controller.scheduledTime));
    } catch (error) {
      console.error("Star history snapshot failed", safeError(error));
    }
  }

  await env.DB.prepare(
    "DELETE FROM cron_runs WHERE created_at < datetime('now', '-7 days')",
  ).run();
}

function safeError(error: unknown): { name: string; message: string } {
  if (error instanceof Error) {
    return { name: error.name, message: error.message.slice(0, 300) };
  }
  return { name: "UnknownError", message: "unknown scheduled sync failure" };
}
