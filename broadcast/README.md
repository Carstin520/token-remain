# TokenRemain Broadcast

This Worker is the owner-managed source for TokenRemain's public X feed. X and
APNs credentials exist only as Cloudflare Worker secrets. Apple clients never
receive or store an X credential.

## Collection policy

- Primary: `btibor91`, `sama`, `claudeai`, `AnthropicAI`, `OpenAI`,
  `karpathy`, and `JensenHuang`; checked every 10 minutes, with an aggregate
  UTC-day limit of 30.
- Rotating: only `Kimi_Moonshot`, `AIatMeta`, `GoogleDeepMind`, `xai`,
  `MistralAI`, `deepseek_ai`, `OpenRouterAI`, `perplexity_ai`, `simonw`,
  `emollick`, `ArtificialAnlys`, and `elonmusk`. The Worker checks this strict
  allowlist hourly and ranks posts by engagement, account reach/activity, and
  recency, with an aggregate UTC-day limit of 20 and a per-author limit of 3.
  Stronger posts discovered later can replace weaker rotating items without
  exceeding the daily public limit. Primary accounts are not present in this
  allowlist and are rejected if returned for the rotating tier.
- Both queries and ingestion reject replies, reposts, quote posts, and
  nullcasts. Apple clients receive only the resulting public feed.

## Local, no-secret validation

```bash
npm install
npm run types
npm run check
npm run db:migrate:local
npm run dev
```

`GET http://127.0.0.1:8787/health` and
`GET http://127.0.0.1:8787/v1/ai-feed` work without external credentials.

The public website uses two additional credential-free endpoints:

- `GET /v1/downloads/macos` increments one anonymous aggregate counter and
  redirects to the current notarized GitHub Release DMG.
- `GET /v1/downloads/stats` returns the public aggregate Mac download count.

The counter stores only one integer and its update time. It does not store IP
addresses, device identifiers, user agents, cookies, or per-download events.

## Production bindings

Provision these Cloudflare resources before deployment:

- D1 database: `tokenremain-broadcast`
- Queue: `tokenremain-push`
- Worker secrets: `ADMIN_TOKEN`, `X_BEARER_TOKEN`, `APNS_KEY_ID`,
  `APNS_TEAM_ID`, and `APNS_PRIVATE_KEY`
- Plain configuration: APNs environment/topics and the daily digest local hour

Do not place secrets in `wrangler.jsonc`, `.dev.vars.example`, source files, CI
logs, or chat. `.dev.vars` is ignored and is for local integration only.

The deployment remains intentionally paused until the owner supplies the X and
APNs credentials through Cloudflare's interactive secret entry.

## Resume checklist

Run these from `broadcast/` after the owner authorizes Cloudflare in the browser:

```bash
npx wrangler login
npx wrangler d1 create tokenremain-broadcast
npx wrangler queues create tokenremain-push
```

Copy only the D1 `database_id` returned by Wrangler into `wrangler.jsonc`.
The primary X account list is public, version-controlled policy in
`src/x-api.ts`; users never configure X accounts or credentials. Then enter
owner-managed secrets interactively:

```bash
npx wrangler secret put X_BEARER_TOKEN
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_PRIVATE_KEY
npx wrangler secret put ADMIN_TOKEN
```

The APNs private key input must be the complete `.p8` contents. Never paste any
of these values into source, documentation, an issue, or chat.

Finish with:

```bash
npx wrangler d1 migrations apply tokenremain-broadcast --remote
npm run check
npx wrangler deploy
```

After deployment, use the Worker HTTPS origin as
`TOKENREMAIN_BROADCAST_BASE_URL` for the Apple builds. Production releases must
also use APNs-enabled provisioning profiles matching
`com.jamesli.usagedock` and `com.jamesli.tokenremain`.
