CREATE TABLE IF NOT EXISTS download_counter_history (
    asset TEXT NOT NULL,
    day TEXT NOT NULL,
    total_count INTEGER NOT NULL DEFAULT 0 CHECK (total_count >= 0),
    updated_at TEXT NOT NULL,
    PRIMARY KEY (asset, day)
);

INSERT OR IGNORE INTO download_counter_history (asset, day, total_count, updated_at)
SELECT asset, date('now'), total_count, updated_at FROM download_counters;
