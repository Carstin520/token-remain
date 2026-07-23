PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS feed_items (
    id TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    author_username TEXT NOT NULL,
    author_display_name TEXT NOT NULL,
    published_at TEXT NOT NULL,
    url TEXT NOT NULL,
    priority TEXT NOT NULL CHECK (priority IN ('token_reset', 'major_update', 'normal')),
    tier TEXT NOT NULL CHECK (tier IN ('primary', 'rotating')),
    likes INTEGER NOT NULL DEFAULT 0,
    reposts INTEGER NOT NULL DEFAULT 0,
    replies INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'published' CHECK (status IN ('draft', 'published', 'archived')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_feed_items_publication
    ON feed_items(status, published_at DESC);

CREATE TABLE IF NOT EXISTS devices (
    installation_id TEXT PRIMARY KEY,
    registration_key_hash TEXT NOT NULL,
    apns_token TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('macos', 'ios', 'ipados')),
    locale TEXT NOT NULL,
    timezone TEXT NOT NULL,
    notifications_enabled INTEGER NOT NULL DEFAULT 1 CHECK (notifications_enabled IN (0, 1)),
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_apns_token
    ON devices(apns_token);
CREATE INDEX IF NOT EXISTS idx_devices_delivery
    ON devices(active, notifications_enabled, timezone);

CREATE TABLE IF NOT EXISTS push_deliveries (
    id TEXT PRIMARY KEY,
    dedupe_key TEXT NOT NULL UNIQUE,
    installation_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('item', 'daily_digest')),
    item_id TEXT,
    digest_local_date TEXT,
    status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'failed')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL,
    sent_at TEXT,
    FOREIGN KEY (installation_id) REFERENCES devices(installation_id) ON DELETE CASCADE,
    FOREIGN KEY (item_id) REFERENCES feed_items(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_push_deliveries_status
    ON push_deliveries(status, created_at);

CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cron_runs (
    execution_key TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
);
