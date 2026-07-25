export type Platform = "macos" | "ios" | "ipados";
export type FeedPriority = "token_reset" | "major_update" | "normal";
export type FeedTier = "primary" | "rotating";
export type PushKind = "item" | "daily_digest";

export interface PushJob {
  deliveryId: string;
  installationId: string;
}

export interface Env {
  DB: D1Database;
  PUSH_QUEUE: Queue<PushJob>;
  ENVIRONMENT: string;
  APNS_ENVIRONMENT: "sandbox" | "production";
  APNS_TOPIC_MACOS: string;
  APNS_TOPIC_IOS: string;
  DAILY_DIGEST_LOCAL_HOUR: string;
  ADMIN_TOKEN?: string;
  X_BEARER_TOKEN?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
}

export interface FeedItemRow {
  id: string;
  text: string;
  author_username: string;
  author_display_name: string;
  published_at: string;
  url: string;
  priority: FeedPriority;
  tier: FeedTier;
  likes: number;
  reposts: number;
  replies: number;
  selection_score: number;
  status: "draft" | "published" | "archived";
}

export interface DeviceRow {
  installation_id: string;
  registration_key_hash: string;
  apns_token: string;
  platform: Platform;
  locale: string;
  timezone: string;
  notifications_enabled: number;
  active: number;
}

export interface DeliveryRow {
  id: string;
  dedupe_key: string;
  installation_id: string;
  kind: PushKind;
  item_id: string | null;
  digest_local_date: string | null;
  status: "queued" | "sending" | "sent" | "failed";
  attempt_count: number;
}
