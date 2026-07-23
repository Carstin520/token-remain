import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import type { Env } from "../src/types";

declare module "cloudflare:workers" {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}
