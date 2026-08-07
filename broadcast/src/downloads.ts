import { json } from "./http";
import type { Env } from "./types";

const MACOS_ASSET = "macos_dmg";
const MACOS_DOWNLOAD_URL =
  "https://github.com/Carstin520/token-remain/releases/latest/download/TokenRemain.dmg";

export async function redirectToMacDownload(env: Env): Promise<Response> {
  const now = new Date();
  const iso = now.toISOString();
  await env.DB.prepare(
    `INSERT INTO download_counters (asset, total_count, updated_at)
     VALUES (?, 1, ?)
     ON CONFLICT(asset) DO UPDATE SET
       total_count = total_count + 1,
       updated_at = excluded.updated_at`,
  )
    .bind(MACOS_ASSET, iso)
    .run();
  await snapshotDownloadHistory(env, now);

  return new Response(null, {
    status: 302,
    headers: {
      "cache-control": "no-store",
      location: MACOS_DOWNLOAD_URL,
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

export async function getDownloadStats(env: Env): Promise<Response> {
  const row = await env.DB.prepare(
    "SELECT total_count, updated_at FROM download_counters WHERE asset = ?",
  )
    .bind(MACOS_ASSET)
    .first<{ total_count: number; updated_at: string }>();

  return json(
    {
      macos: {
        totalDownloads: row?.total_count ?? 0,
        updatedAt: row?.updated_at ?? null,
      },
    },
    {
      headers: {
        "access-control-allow-origin": "*",
        "cache-control": "public, max-age=60",
      },
    },
  );
}

export async function snapshotDownloadHistory(env: Env, now: Date): Promise<void> {
  const iso = now.toISOString();
  const day = iso.slice(0, 10);
  await env.DB.prepare(
    `INSERT INTO download_counter_history (asset, day, total_count, updated_at)
     SELECT asset, ?, total_count, ? FROM download_counters
     WHERE true
     ON CONFLICT(asset, day) DO UPDATE SET
       total_count = excluded.total_count,
       updated_at = excluded.updated_at`,
  )
    .bind(day, iso)
    .run();
}

interface HistoryRow {
  day: string;
  total_count: number;
}

async function readMacHistory(env: Env): Promise<HistoryRow[]> {
  const rows = await env.DB.prepare(
    "SELECT day, total_count FROM download_counter_history WHERE asset = ? ORDER BY day ASC",
  )
    .bind(MACOS_ASSET)
    .all<HistoryRow>();
  return rows.results;
}

export async function getDownloadHistory(env: Env): Promise<Response> {
  const rows = await readMacHistory(env);
  return json(
    {
      macos: {
        days: rows.map((row) => ({ day: row.day, totalDownloads: row.total_count })),
      },
    },
    {
      headers: {
        "access-control-allow-origin": "*",
        "cache-control": "public, max-age=3600",
      },
    },
  );
}

// The counter only ever grows, so missing days (no cron write, no download)
// carry the last known total forward up to the current UTC day, and a stale
// low row can never pull the cumulative line back down.
function forwardFillDaily(rows: HistoryRow[], today: string): HistoryRow[] {
  if (rows.length === 0) return [];
  const byDay = new Map(rows.map((row) => [row.day, row.total_count]));
  const filled: HistoryRow[] = [];
  let cursor = new Date(`${rows[0]!.day}T00:00:00.000Z`);
  const end = new Date(`${today}T00:00:00.000Z`);
  let last = rows[0]!.total_count;
  while (cursor.getTime() <= end.getTime()) {
    const day = cursor.toISOString().slice(0, 10);
    last = Math.max(last, byDay.get(day) ?? last);
    filled.push({ day, total_count: last });
    cursor = new Date(cursor.getTime() + 86_400_000);
  }
  return filled;
}

interface ChartTheme {
  series: string;
  text: string;
  textDim: string;
  grid: string;
  ring: string;
}

const CHART_THEMES: Record<string, ChartTheme> = {
  dark: {
    series: "#8F7BF2",
    text: "#E9EDF5",
    textDim: "#8B97AB",
    grid: "rgba(139,151,171,0.22)",
    ring: "#0D1117",
  },
  light: {
    series: "#5B4FB0",
    text: "#1F2430",
    textDim: "#57617A",
    grid: "rgba(87,97,122,0.22)",
    ring: "#FFFFFF",
  },
};

const CHART_LABELS: Record<string, { caption: string; empty: string }> = {
  en: { caption: "Website downloads · cumulative", empty: "Collecting first data points…" },
  zh: { caption: "官网累计下载", empty: "正在积累最初的数据点…" },
};

function niceCeiling(value: number): number {
  if (value <= 10) return 10;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 2.5, 5, 10]) {
    const candidate = magnitude * step;
    if (candidate >= value) return candidate;
  }
  return magnitude * 10;
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

export async function getDownloadChart(env: Env, url: URL): Promise<Response> {
  const theme = CHART_THEMES[url.searchParams.get("theme") ?? "dark"] ?? CHART_THEMES.dark!;
  const labels = CHART_LABELS[url.searchParams.get("lang") ?? "en"] ?? CHART_LABELS.en!;
  const today = new Date().toISOString().slice(0, 10);
  const points = forwardFillDaily(await readMacHistory(env), today);

  const width = 920;
  const height = 300;
  const margin = { top: 68, right: 32, bottom: 40, left: 60 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;

  const mono = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
  const parts: string[] = [];
  parts.push(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="img" aria-label="${escapeXml(labels.caption)}">`,
  );

  const latest = points.at(-1)?.total_count ?? 0;
  parts.push(
    `<text x="${margin.left}" y="34" font-family="${mono}" font-size="15" letter-spacing="2" fill="${theme.textDim}">${escapeXml(labels.caption.toUpperCase())}</text>`,
    `<text x="${width - margin.right}" y="40" text-anchor="end" font-family="${mono}" font-size="30" font-weight="600" fill="${theme.text}">${latest}</text>`,
  );

  if (points.length === 0) {
    parts.push(
      `<text x="${width / 2}" y="${height / 2 + 10}" text-anchor="middle" font-family="${mono}" font-size="15" fill="${theme.textDim}">${escapeXml(labels.empty)}</text>`,
      "</svg>",
    );
  } else {
    const yMax = niceCeiling(Math.max(...points.map((point) => point.total_count)));
    const x = (index: number): number =>
      points.length === 1
        ? margin.left + plotWidth / 2
        : margin.left + (plotWidth * index) / (points.length - 1);
    const y = (value: number): number =>
      margin.top + plotHeight - (plotHeight * value) / yMax;

    for (let tick = 0; tick <= 4; tick += 1) {
      const value = (yMax * tick) / 4;
      const lineY = y(value);
      parts.push(
        `<line x1="${margin.left}" y1="${lineY}" x2="${width - margin.right}" y2="${lineY}" stroke="${theme.grid}" stroke-width="1"/>`,
        `<text x="${margin.left - 10}" y="${lineY + 4}" text-anchor="end" font-family="${mono}" font-size="12" fill="${theme.textDim}">${value}</text>`,
      );
    }

    const labelCount = Math.min(6, points.length);
    const seen = new Set<number>();
    for (let slot = 0; slot < labelCount; slot += 1) {
      const index =
        labelCount === 1 ? 0 : Math.round(((points.length - 1) * slot) / (labelCount - 1));
      if (seen.has(index)) continue;
      seen.add(index);
      parts.push(
        `<text x="${x(index)}" y="${height - 14}" text-anchor="middle" font-family="${mono}" font-size="12" fill="${theme.textDim}">${points[index]!.day.slice(5)}</text>`,
      );
    }

    const coordinates = points.map(
      (point, index) => `${x(index).toFixed(2)},${y(point.total_count).toFixed(2)}`,
    );
    if (points.length > 1) {
      const baseline = y(0).toFixed(2);
      parts.push(
        `<polygon points="${coordinates[0]!.split(",")[0]},${baseline} ${coordinates.join(" ")} ${coordinates.at(-1)!.split(",")[0]},${baseline}" fill="${theme.series}" fill-opacity="0.14"/>`,
        `<polyline points="${coordinates.join(" ")}" fill="none" stroke="${theme.series}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,
      );
    }
    const lastPoint = points.at(-1)!;
    parts.push(
      `<circle cx="${x(points.length - 1)}" cy="${y(lastPoint.total_count)}" r="4" fill="${theme.series}" stroke="${theme.ring}" stroke-width="2"/>`,
      "</svg>",
    );
  }

  return new Response(parts.join("\n"), {
    headers: {
      "content-type": "image/svg+xml; charset=utf-8",
      "access-control-allow-origin": "*",
      "cache-control": "public, max-age=3600",
      "x-content-type-options": "nosniff",
    },
  });
}
