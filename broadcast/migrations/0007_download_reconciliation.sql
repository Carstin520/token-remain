-- Reconciliation recorded 2026-08-08: the public website bypassed the Worker
-- redirect after migration 0005, while the fixed-name TokenRemain.dmg assets
-- rose from 163 to 188 cumulative GitHub download requests. Raise the D1
-- counter once; the hourly Worker reconciliation keeps it current thereafter.
UPDATE download_counters
SET total_count = 188,
    updated_at = '2026-08-08T14:08:25Z'
WHERE asset = 'macos_dmg' AND total_count < 188;

INSERT INTO download_counter_history (asset, day, total_count, updated_at)
SELECT asset, '2026-08-08', total_count, updated_at FROM download_counters WHERE true
ON CONFLICT(asset, day) DO UPDATE SET
    total_count = MAX(download_counter_history.total_count, excluded.total_count),
    updated_at = excluded.updated_at;
