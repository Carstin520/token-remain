-- Baseline recorded 2026-08-07: 163 cumulative downloads of the fixed-name
-- TokenRemain.dmg asset across all GitHub Releases (v1.0.0..v1.2.10) — the file
-- the website download button has always redirected to. The 13 downloads the
-- worker counted since 2026-07-25 are a subset of those 163, so the counter is
-- raised to the baseline rather than incremented by it. Per-release breakdown:
-- docs/download-baseline.md. Only ever raises the counter, never lowers it.
UPDATE download_counters
SET total_count = 163,
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE asset = 'macos_dmg' AND total_count < 163;

INSERT INTO download_counter_history (asset, day, total_count, updated_at)
SELECT asset, date('now'), total_count, updated_at FROM download_counters WHERE true
ON CONFLICT(asset, day) DO UPDATE SET
    total_count = MAX(download_counter_history.total_count, excluded.total_count),
    updated_at = excluded.updated_at;
