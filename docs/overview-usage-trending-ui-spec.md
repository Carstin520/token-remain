# Overview usage + trending UI specification

## Product goal

Make the Overview denser without losing meaning:

1. Merge “今日用量构成” and “今日成本构成” into one compact card using the existing donut visual language.
2. Use the freed lower-left card slot for the top 1–2 currently trending AI Feed posts.
3. Keep the full AI Feed below the four-card overview grid.

## Frozen data logic

Do not change ranking or usage logic.

- The donut encodes **estimated cost share only**. Mixing token and currency units in one ring is prohibited.
- The donut center displays `insights.totalCost` as today’s estimated total cost.
- Provider rows display all of:
  - provider name and color;
  - token total;
  - estimated cost;
  - cost share from `insights.costShare(for:)`.
- Trending posts come only from `feedStore.topStories`.
- `topStories` is already ranked by relevance, age-adjusted engagement velocity, freshness, source trust, and important-event boosts.
- Internal source tiers and monitored-account selection must remain invisible.

## Overview layout

Keep the current two-column structure:

```text
KPI row

[ Combined usage + cost ] [ Official quota ]
[ Trending AI Feed      ] [ Risk detail    ]

Full AI Feed
```

Both cards in each row should use equal flexible width. Do not increase the Dashboard minimum width.

## Combined usage + cost card

- Title: `今日用量与成本`
- Subtitle: `按服务商统计 · 本地 ccusage`
- Reuse `DashboardCard`, `RingChart`, `DashboardTheme`, and existing formatting helpers.
- Use an approximately 104–112 pt donut.
- Center:
  - main: total cost, such as `$252.15`;
  - subordinate label: `今日预估`.
- Right side contains dense provider rows.
- Each provider row:
  - colored dot;
  - provider;
  - compact token count;
  - cost;
  - bold cost-share percentage.
- Remove the old horizontal composition bars and the separate cost card.
- Preserve an honest no-data state.

## Trending card

- Title: `Trending`
- Subtitle: `此刻最值得关注`
- Render at most two posts from `feedStore.topStories`.
- The whole post row is clickable and opens `post.postURL`.
- Each row includes:
  - rank treatment (`#1` / `#2`) and flame/bolt symbol;
  - author and relative time;
  - post text limited to two lines;
  - compact reply/repost/like counts.
- Strongly communicate “the most trending”:
  - rank 1: warm orange/red accent, stronger border/background glow;
  - rank 2: purple/magenta accent, quieter than rank 1;
  - do not use these accents for unrelated container chrome.
- Keep the visual compact enough to align with the risk card.
- Empty state: `正在捕捉热门动态…`.
- Add accessibility labels and hints; retain keyboard-click behavior through `Button`.

## File boundaries

Preferred changes:

- Edit `Sources/UsageDock/Views/Dashboard/OverviewSection.swift`.
- Optionally add focused view files under `Sources/UsageDock/Views/Dashboard/`.
- Do not edit:
  - `AIFeedCollectionPolicy.swift`;
  - `AIFeedStore.swift`;
  - `UsageInsights.swift`;
  - services, caches, or tests.

## Visual reference

Use the user-provided screenshot only for the donut/card language:

`/Users/jamesli/Desktop/截屏2026-07-18 18.36.44.png`

Match the existing UsageDock dark theme rather than copying screenshot dimensions literally.
