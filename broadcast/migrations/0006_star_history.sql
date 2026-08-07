CREATE TABLE IF NOT EXISTS star_history (
    day TEXT PRIMARY KEY,
    star_count INTEGER NOT NULL DEFAULT 0 CHECK (star_count >= 0),
    updated_at TEXT NOT NULL
);

-- Seed recorded 2026-08-07: 15 stars on Carstin520/token-remain.
INSERT OR IGNORE INTO star_history (day, star_count, updated_at)
VALUES (date('now'), 15, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
