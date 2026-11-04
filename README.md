# T3 Code Bar

Keep an eye on your [T3 Code](https://github.com/pingdotgg/t3code) agents from the
[Noctalia](https://github.com/noctalia-dev/noctalia) bar. The widget counts threads that
are waiting for you or still working. Its panel lists your threads and shows how much of
your Codex and Claude subscription limits is left.

A community plugin inspired by the macOS menu bar app
[eliophan/t3code-bar](https://github.com/eliophan/t3code-bar). It is not affiliated with
or endorsed by T3 Tools.

## Features

- Bar count of threads waiting for approval or input, or else of threads working, colored
  by urgency.
- **Threads** tab: pinned, waiting, working, then your most recent threads in one list.
  Click a thread to open it in T3 Code.
- **Usage** tab: 5-hour, weekly and model-scoped limits for Codex and Claude, pooled
  across accounts with T3 Code's own calculation, plus pace, reset time and next refill.
- Saved threads stay visible while T3 Code is closed.
- Read-only: it never writes to T3 Code's database or files.

## Plugin

| Field | Value |
| --- | --- |
| ID | `PedroRBC/t3code-bar` |
| Entries | Bar widget: `status`; panel: `panel`; service: `backend` |
| Plugin API | 24 |

## Requirements

- Noctalia with plugin API 24 or later.
- `python3`, standard library only. A small helper reads T3 Code's local database.
- `xdg-open` (from `xdg-utils`), used to open a thread's `t3code://` link.
- T3 Code installed and opened at least once.
- For the Usage tab only: a [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
  hub that holds your Codex and/or Claude accounts, and its management key. The Threads
  tab works without it.

## Install

Add this repository as a local plugin source and enable the plugin:

```sh
git clone https://github.com/PedroRBC/t3code-bar-noctalia.git
cd t3code-bar-noctalia
noctalia msg plugins source add t3code-bar-local path "$PWD"
noctalia msg plugins enable PedroRBC/t3code-bar
```

The source root is the repository root, which contains the `t3code-bar/` plugin
directory. To update, `git pull` in the clone.

## Usage

Add the bar widget `PedroRBC/t3code-bar:status` from Noctalia's widget picker, or by
hand. Keep your other widgets in the array:

```toml
[widget.t3code]
type = "PedroRBC/t3code-bar:status"

[bar.default]
end = ["t3code", "tray", "session"]
```

The widget shows the official T3 Code icon and a count: waiting threads when any need you (in the
`error` color), otherwise working threads (in `primary`). The count hides at zero and the
icon dims while T3 Code is offline. The tooltip repeats the counts and the 5-hour limit
left per provider.

Click the widget to toggle the panel. You can also toggle it from a script or a
compositor binding:

```sh
noctalia msg panel-toggle PedroRBC/t3code-bar:panel
```

### Threads tab

Each row shows the project, a status, the thread title, and the branch and provider when
known. Pinned threads carry a pin glyph. Clicking a row opens the thread in T3 Code and
closes the panel.

| Status | Meaning |
| --- | --- |
| Approval | The thread, or one of its subagents, is waiting for you to approve an action. |
| Input | The thread, or one of its subagents, is waiting for your answer. |
| Connecting | A run is starting. |
| Working / Goal | A run is in progress, with elapsed time. Goal means goal mode is on. |
| Failed | The latest run failed or the session reported an error. |
| Plan ready | A proposed plan is ready in plan mode. |
| Done | The latest run finished after your last visit to the thread. |
| `5m`, `2h`, `3d` | Nothing above applies; time since the thread's latest message. |

Archived and deleted threads, side chats and subagent threads are left out. A subagent's
pending approval or input marks its root thread as waiting.

### Usage tab

One section per provider, with one card per limit window (5 hours first, then weekly,
then others). Each card shows the percentage left, a pace marker (ahead of, on or under
pace), a bar split into one segment per account, the reset time, and the next refill when
the pool has more than one account. Segments are labelled with e-mail initials, never full
addresses. An account whose weekly limit is used up adds nothing to its 5-hour pool, as in
T3 Code. The footer shows when usage was last read and has a **Refresh** button.

## Settings

Edited under Settings → Plugins → T3 Code Bar.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `hub_url` | `string` | empty | CLIProxyAPI hub base URL, for example `https://host:8317`, without a management path. |
| `management_key` | `string` | empty | Hub management key. |
| `limits_refresh_minutes` | `int` | `5` | Usage refresh interval in minutes, 1 to 60. |
| `latest_count` | `int` | `10` | Recent threads listed after pinned, waiting and working ones, 0 to 50. `0` hides them. |

While the hub URL or key is empty, the Usage tab shows a button that opens these settings.

The helper reads `~/.t3` by default. If T3 Code uses another directory, set `T3CODE_HOME`
in the environment Noctalia runs in; the helper appends `/userdata`.

## Privacy and data

- **Threads.** Every 2 seconds the service runs `python3 scripts/t3bar.py threads`, which
  opens `${T3CODE_HOME:-~/.t3}/userdata/statev2.sqlite` in read-only mode and reads
  `server-runtime.json` and `environment-id` next to it. It does not write to T3 Code,
  call its server or use its MCP. Runs never overlap.
- **Usage.** Through `noctalia.http`, the service calls the hub's `auth-files` and
  `api-call` management endpoints. The hub then asks Anthropic and ChatGPT for each
  account's usage. Reset credits are never read or redeemed. Usage refreshes on start, at
  the configured interval, on **Refresh**, and when the panel opens if the last reading is
  older than one minute. An account that fails drops out of the pools and its error is
  shown. If every account fails, the last good reading stays.
- **Management key.** It is sent only in the HTTP `Authorization` header and never
  enters process arguments, shared state or the UI. Noctalia stores plugin settings in
  plain text in `~/.local/state/noctalia/settings.toml`. The key is not marked `secret`
  yet, because that needs plugin API 47.
- The plugin never reads T3 Code's own config or secret store, collects no telemetry,
  and spawns only the Python helper and, when you click a thread, `xdg-open`.

When you share screenshots or bug reports, check them for thread titles, project names,
branches and e-mail initials.

## Troubleshooting

| Message | What to check |
| --- | --- |
| T3 Code data not found | Start T3 Code once, or check `T3CODE_HOME`. |
| Cannot read T3 Code data | File permissions on the data directory, and that `python3` is on `PATH`. |
| Database schema changed | Your T3 Code version stores threads differently. Update the plugin. |
| Database is busy | Nothing; the next read 2 seconds later usually succeeds. |
| T3 Code offline | T3 Code is not running. Saved threads stay visible without live status. |
| Configure the CLIProxyAPI hub | Set `hub_url` and `management_key`. |
| Hub access refused | HTTP 401 or 403: check the management key. |
| Enter a valid hub URL | Use `http://` or `https://` with no credentials, query or fragment, and remove line breaks from the key. |
| Cannot reach the hub | The hub URL, your network and the TLS certificate. |

For a bug report, [open an issue](https://github.com/PedroRBC/t3code-bar-noctalia/issues)
with your Noctalia and T3 Code versions and the steps to reproduce. Do not attach your T3
Code database or your management key.

## Known limitations

- Reads T3 Code's internal projection-v2 tables, which can change between versions.
  Tested with T3 Code 0.1.8 nightly on Noctalia 5.4.1.
- Monitors one local T3 Code instance.
- Usage needs a CLIProxyAPI hub and covers Codex and Claude only. Threads from other
  providers, such as OpenCode, are listed without limits.
- The management key is stored unencrypted until Noctalia supports `secret` settings for
  this plugin.
- English only. No notifications, snooze or search.

## Development

```
t3code-bar/
  plugin.toml          manifest and settings
  service.luau         polls the helper and the hub, publishes shared state
  widget.luau          bar widget
  panel.luau           Threads and Usage tabs
  limits.luau          hub responses to T3-style pools (pure, no Noctalia globals)
  scripts/t3bar.py     read-only SQLite helper, prints JSON
  translations/en.json
tests/
  test_threads.py      helper against synthetic SQLite fixtures
  test_limits.py       limits.luau under /usr/bin/lua with synthetic accounts
```

Run the checks from the repository root:

```sh
noctalia plugins lint t3code-bar
python3 -m unittest discover -s tests -v
```

Tests make no network requests and use synthetic data only. The helper's JSON and the
UI behavior are described in the
[design contract](docs/superpowers/specs/2026-11-04-t3code-bar-design.md).

## Credits

- [T3 Code](https://github.com/pingdotgg/t3code) (MIT). The usage pooling in
  `limits.luau` follows its `usageLimits.ts`, `claudeUsageLimits.ts`,
  `codexUsageLimits.ts` and `cliproxyApi.ts`, so the numbers match its Usage → Limits view.
- [eliophan/t3code-bar](https://github.com/eliophan/t3code-bar) (MIT), the macOS menu bar
  app this plugin is modelled on. The thread query and status rules are ported from it.
- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (MIT), the hub that serves
  the usage readings.
- [Noctalia](https://github.com/noctalia-dev/noctalia) and its plugin API.

## License

[MIT](LICENSE). T3 Code, and other names belong to their respective
owners. Their use here does not imply endorsement or an official relationship.
