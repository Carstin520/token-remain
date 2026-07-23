ALTER TABLE feed_items
    ADD COLUMN selection_score REAL NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_feed_items_daily_selection
    ON feed_items(tier, status, published_at, selection_score);
