# T3 Code Bar for Noctalia

A Luau plugin for the Noctalia C++ shell. The bar shows waiting or working thread
counts. Click it for **Threads** and **Usage** tabs.

Threads appear in one list: pinned, waiting, working, then recent threads, in the
helper's order. Click a thread to open it in T3 Code. Offline reads still show saved
threads. Usage pools Codex and Claude subscription limits using T3 Code's own
calculation, including weekly exhaustion blocking an account's 5-hour allowance.
Account segments show e-mail initials.

## Install

Requires Noctalia with plugin API 24+, `python3`, and `xdg-open`.
The plugin source root is this repository, containing the `t3code-bar/` directory.

```sh
noctalia msg plugins source add t3code-bar-local path "$PWD"   # run from the repo root
noctalia msg plugins enable PedroRBC/t3code-bar
```

Add a named widget to your Noctalia configuration, and include `"t3code"` in an
existing `[bar.default]` widget array. Preserve your other widgets; for example:

```toml
[widget.t3code]
type = "PedroRBC/t3code-bar:status"

[bar.default]
end = ["t3code", "tray", "session"]
```

In **Settings → Plugins → T3 Code Bar**, set **CLIProxyAPI hub URL** and
**Management key**. Use the hub's base URL, such as `https://host:8317`, without a
management endpoint suffix. Leave either field empty to get a settings prompt.

## Settings and data

| Setting | Default | Range |
| --- | --- | --- |
| Hub URL | Empty | HTTP or HTTPS base URL |
| Management key | Empty | String |
| Usage refresh interval | 5 minutes | 1–60 minutes |
| Latest threads | 10 | 0–50 |

The service reads threads every 2 seconds. Usage refreshes on start, at the
configured interval, on manual refresh, and on panel open when older than 60
seconds. Reads do not overlap; failures retain the last successful reading and
show an error. HTTP 401/403 prompts you to check the management key.

The Python helper reads `${T3CODE_HOME:-~/.t3}/userdata/statev2.sqlite` in read-only
mode, plus `server-runtime.json` and `environment-id`. It does not write to T3 Code
or use its server/MCP. Usage uses the separately configured CLIProxyAPI hub's
`auth-files` and `api-call` management endpoints. No reset credits are read or
redeemed. The management key stays in the service and HTTP Authorization header;
it never enters process arguments, shared state, or UI. Noctalia stores it in plain
text in `config.toml`; it is not marked `secret` yet because that needs plugin API 47
(Noctalia 5.4.1 supports up to 43), so `noctalia config export` will include it.

## Verify

```sh
noctalia plugins lint t3code-bar
python3 -m unittest discover -s tests -p 'test_limits.py' -v
python3 -m unittest discover -s tests -p 'test_threads.py' -v
```

The limit tests use `/usr/bin/lua` and synthetic accounts. Tests make no network
requests. See [the design contract](docs/superpowers/specs/2026-11-04-t3code-bar-design.md)
for the helper JSON and UI behavior.
