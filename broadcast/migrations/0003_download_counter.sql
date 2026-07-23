CREATE TABLE IF NOT EXISTS download_counters (
    asset TEXT PRIMARY KEY,
    total_count INTEGER NOT NULL DEFAULT 0 CHECK (total_count >= 0),
    updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO download_counters (asset, total_count, updated_at)
VALUES ('macos_dmg', 0, '2026-07-23T00:00:00.000Z');
