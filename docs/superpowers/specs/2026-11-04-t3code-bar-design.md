# T3 Code Bar for Noctalia — design

A Noctalia 5.x plugin (plugin.toml + Luau, plus a small Python helper) that shows
T3 Code (https://github.com/pingdotgg/t3code) state in the bar, inspired by the macOS
app https://github.com/eliophan/t3code-bar. Personal tool for this machine
(Noctalia 5.4.1, T3 Code nightly 0.1.8, CachyOS/Hyprland).

## Goals

- Bar widget: glance at what T3 Code agents are doing and whether one needs you.
- Panel with two tabs:
  1. **Threads** (default): one list, no section headers.
  2. **Usage**: provider usage limits (5-hour and weekly). Mandatory, and the numbers
     must match T3 Code's own Usage → Limits view.

## Non-goals (v1)

Tokens/cost charts, snooze/wake, search, creating threads, notifications/sounds,
writing anything to T3 Code, talking to the T3 Code server or its MCP.

## Anti-goals

- Never write to T3 Code's files or database.
- Never read T3 Code's config or secret store for usage limits; the CLIProxyAPI hub is
  configured in this plugin's own Noctalia settings.
- Never put the management key in argv, logs, notifications or the UI.

## Repository layout (mirrors the user's PedroRBC/truenas plugin)

```
t3code-bar-noctalia/            # repo root = Noctalia "path" plugin source root
  t3code-bar/                   # the plugin directory
    plugin.toml
    service.luau                # polls helper + hub, publishes noctalia.state
    widget.luau                 # bar widget
    panel.luau                  # 2-tab panel
    limits.luau                 # pure: hub responses -> T3-style pools (no noctalia globals)
    translations/en.json
    scripts/t3bar.py            # python3 stdlib only
  tests/
    test_threads.py             # unittest, synthetic fixture SQLite
    test_limits.py              # unittest running limits.luau under `lua` (like truenas tests)
  README.md
```

Plugin id `PedroRBC/t3code-bar`, name "T3 Code Bar", author `PedroRBC`, license MIT,
dependencies `["python3", "xdg-open"]`. Entries: `[[service]] id="backend"`,
`[[widget]] id="status"`, `[[panel]] id="panel"` (attached, open near click, ~380x560).
Declare the lowest `plugin_api` that covers the features used (argv runAsync = 24,
`http`, `secret` settings, `state`); confirm with `noctalia plugins lint t3code-bar`.

Settings (`[[setting]]`, labels via translations):
- `hub_url` string, default `""` — CLIProxyAPI base URL (e.g. `https://host:8317`).
- `management_key` string, `secret = true`, default `""`.
- `limits_refresh_minutes` int, default 5, min 1, max 60.
- `latest_count` int, default 10, min 0, max 50.

## Data source 1 — threads (Python helper)

`python3 t3code-bar/scripts/t3bar.py threads` prints one JSON object to stdout, exit 0
even on soft errors (error is in the JSON). Reads only:

- `${T3CODE_HOME:-~/.t3}/userdata/statev2.sqlite`, opened `file:...?mode=ro`
  (not immutable, so WAL is visible), `busy_timeout` 250 ms.
- `${T3CODE_HOME:-~/.t3}/userdata/server-runtime.json` (pid, port, serverVersion) and
  `.../environment-id` (plain text).

Live tables are `orchestration_v2_projection_*` (the legacy `projection_threads` is empty).
Port the query and status logic from t3code-bar (`Sources/Data/DatabaseManager.swift`
`fetchActiveThreads`, `Sources/Data/ThreadModel.swift`), checking columns against the real
schema (`sqlite3 'file:...?mode=ro' '.schema <table>'`, schema/counts only).

Filters: `deleted_at IS NULL`, `archived_at IS NULL`, not a side chat, not a subagent
(`lineage.sideChat`, `lineage.relationshipToParent = 'subagent'`), not `thread:%` ids.

Status per thread (priority high→low): `approval` (pending runtime request, kind ≠
user_input) > `input` (pending user_input request) > `connecting` (run preparing/starting)
> `goal` / `working` (run running/waiting, non-silent; goal when goal mode active) >
`failed` (latest run failed / session error) > `planReady` > `done` (completed after the
thread was last visited) > `idle`.

Groups and order (one list; the helper returns it already sorted):
1. `pinned`: `$.pinnedAt` set in thread payload_json; order `$.pinOrderKey` asc, keyless
   after by createdAt desc. A pinned thread stays here whatever its status.
2. `waiting`: status approval/input.
3. `working`: connecting/goal/working.
4. `latest`: the `latest_count` most recent remaining threads by lastActivityAt
   (most recent of thread updated_at, latest run started/completed, latest user message),
   settled or not. `latest_count` is passed as `--latest N`.
Within groups 2–3, most recent activity first.

Output contract:
```json
{
  "ok": true,
  "error": null,                       // or "missing"|"unavailable"|"incompatibleSchema"|"busy"|"invalidData"
  "online": true,                      // os.kill(pid, 0) succeeds
  "serverVersion": "0.1.8-nightly...",
  "counts": {"waiting": 1, "working": 2},
  "threads": [{
    "id": "…", "title": "…", "projectName": "…",
    "branch": "feature/x",             // or null
    "provider": "codex",               // codex | claudeAgent | opencode | … or null
    "status": "working",
    "group": "working",
    "pinned": false,
    "since": 1793800000000,            // ms: run start (working), request created (waiting), else T3 sidebar time (latest user message ?? updated_at)
    "lastActivityAt": 1793800000000,
    "openUrl": "t3code://threads/<envId>/<threadId>",      // components percent-encoded
    "browserUrl": "http://127.0.0.1:<port>/<envId>/<threadId>"  // null when no port
  }]
}
```
When T3 Code is offline (`online:false`) the last DB contents are still returned; the UI
hides live status words for working/connecting.

## Data source 2 — usage limits (Luau, via `noctalia.http`)

Mirror t3code `apps/server/src/usage/cliproxyApi.ts` exactly:
1. `GET {hub_url}/v0/management/auth-files` with `Authorization: Bearer <management_key>`
   → `{files:[{id, auth_index, provider, email?, disabled?, id_token?{chatgpt_account_id, plan_type}}]}`.
   Keep enabled accounts with provider `codex` or `claude`.
2. Per account `POST {hub_url}/v0/management/api-call` with JSON
   `{auth_index, method:"GET", url, header}` → `{status_code, body}` (body is a JSON string):
   - claude: url `https://api.anthropic.com/api/oauth/usage`, header
     `{"Authorization":"Bearer $TOKEN$","anthropic-beta":"oauth-2025-04-20","User-Agent":"claude-code/2.1.273"}`
     → `five_hour`/`seven_day` `{utilization (0–100), resets_at (ISO)}` plus `limits[]`
     (`kind:"weekly_scoped"` with `scope.model.display_name`).
   - codex: url `https://chatgpt.com/backend-api/wham/usage`, header
     `{"Authorization":"Bearer $TOKEN$","Content-Type":"application/json","OpenAI-Beta":"codex-1","Originator":"Codex Desktop"}`
     plus `Chatgpt-Account-Id` when `id_token.chatgpt_account_id` exists →
     `rate_limit.primary_window/secondary_window {used_percent, reset_at (epoch s), limit_window_seconds}`.
   No reset-credit calls.

Normalize to windows exactly like t3code `apps/server/src/provider/claudeUsageLimits.ts`
and `codexUsageLimits.ts`, then pool exactly like t3code `packages/shared/src/usageLimits.ts`
(`collectLimitPools`, `poolKey`, `poolMember` — weekly at 100% blocks the session window —
`poolWindows`, `remainingPercent`, `elapsedShare`, `paceOfShares` ±5, `formatDuration`,
`formatResetsIn`). Reference check (2026-11-04 ~11:20 local, user confirmed it matches
T3 Code): Codex 2 accounts → 5h **48% left**, weekly **20% left**; Claude → 5h **83%**,
weekly **35%** left.

Refresh: on service start, every `limits_refresh_minutes`, and when the panel opens if the
last read is older than 60 s. Overlapping reads are skipped. On error keep the last good
data and show the error text; HTTP 401/403 → "check the management key"; empty
`hub_url`/`management_key` → "Configure the CLIProxyAPI hub in the plugin settings" with a
button that calls `noctalia.openSettings()`.

## UI

**Bar widget**: a glyph (tabler) for T3 Code; a count = waiting threads, else working
threads, hidden at 0; color by the most urgent status: approval/input → `error`-ish
attention role, working → `primary`, idle → `on_surface`. Tooltip: counts plus a one-line
limits summary ("Codex 48% · Claude 83% left (5h)"). Left click toggles the panel.
Offline: dimmed glyph.

**Panel header**: two tab buttons, "Threads" and "Usage" (selected one emphasized).

**Threads tab**: one scrollable list, rows in helper order, no headers or dividers between
groups. Row: line 1 project name (muted) + right-aligned colored status word with
elapsed/relative time (`Working 3m`, `Approval`, `Input`, `Failed`, `Done`, `5m`/`2h`/`3d`);
line 2 thread title (1 line, elided); line 3 (when present) branch + provider name.
Pinned rows show a pin glyph. Click → `runAsync({"xdg-open", openUrl})` then close the
panel. Notices: "Reading T3 Code data…", "T3 Code offline · showing saved threads",
schema/DB errors with a short hint, "No threads".

**Usage tab**: one section per provider (Codex, Claude; order like T3: codex, claude).
Each section: one card per pooled window (5h first, then weekly, then others), showing
the window label, a big "N% left", a pace marker (ahead/on/under), a bar split into one
segment per account (labelled by e-mail initials, never the full e-mail), "resets in
3h 41m", and "next refill +X% at HH:MM" when the pool has more than one account.
Footer: "Updated X min ago" and a refresh button.

## Decisions made by the builder lead (not the user)

Glyph instead of the T3 logo; default refresh 5 min; latest 10; English-only UI; threads
polled every 2 s; e-mail initials for account labels; Codex local `app-server` not used
(the hub already reports both Codex accounts).

Integration changes (2026-11-04):
- `plugin_api = 24` and no `secret = true`: secret settings need API 47, installed
  Noctalia 5.4.1 supports 3–43. Noctalia stores plugin settings in
  `~/.local/state/noctalia/settings.toml` (`[plugin_settings."PedroRBC/t3code-bar"]`),
  not in the dotfiles `config.toml`.
- A subagent's pending approval/input (nested too, via `$.lineage.rootThreadId`) marks its
  root thread as waiting, like T3's `pendingSubagentRequest`. Side chats do not roll up.
- A hub account that fails drops out of the pools (like T3's `probeFailed`) and its error
  is shown; the last good data is kept only when every account failed.

## Verification

- `python3 -m unittest discover -s tests` passes (fixture DBs are synthetic; never copy
  real thread titles or prompts into tests).
- `noctalia plugins lint t3code-bar` reports 0 errors.
- Live: `python3 t3code-bar/scripts/t3bar.py threads` against the real DB returns ok JSON;
  the Usage tab shows the same "% left" as T3 Code's Limits view.
