# Shelly Desktop Sidecar — MCP Bridge Wire Protocol

Android cannot spawn stdio processes, so stdio MCP servers run on a desktop PC
behind this bridge. The phone app consumes the bridge tools over LAN HTTP and
never talks to the stdio servers directly.

```
Phone (Shelly app)                    Desktop sidecar
┌────────────────────┐   LAN HTTP    ┌──────────────────────────────┐
│ BridgeToolRegistry │ ────────────► │ BridgeServer (dart:io)       │
│  bridge_client.dart│ ◄──────────── │  bridge_server.dart          │
└────────────────────┘               │   ├─ stdio MCP server "a"    │
                                     │   └─ stdio MCP server "b"    │
                                     └──────────────────────────────┘
```

## Endpoints

All endpoints live under the bridge root (default port `8766`).

| Method | Path          | Purpose                                            |
|--------|---------------|----------------------------------------------------|
| POST   | `/list_tools` | Merged tool catalog of every spawned MCP server.   |
| POST   | `/call_tool`  | Route a tool call to the right stdio server.       |
| GET    | `/health`     | Liveness + per-server status.                      |

Any other method/path combination answers `404` with
`{"ok": false, "error": "not found: <METHOD> <path>"}`.

## Authentication

Every request must carry the shared token:

```
X-Shelly-Bridge-Token: <token>
```

A missing or wrong token is answered with `401` and
`{"ok": false, "error": "unauthorized"}` — before any routing happens. The
bridge CLI generates a random token when `--token` is omitted and prints it on
startup; the app stores the same token in its server config.

## Response envelopes

Domain results use a stable two-key envelope:

```json
{"ok": true,  "payload": { ... }}
{"ok": false, "error": "human readable reason"}
```

- `/list_tools` success → `payload` is `{"tools": [ ... ]}`.
- `/call_tool` success → `payload` is the MCP `tools/call` result object
  (typically `{"content": [{"type": "text", "text": "..."}], ...}`).
- `/health` success → flat body `{"ok": true, "servers": [ ... ]}` (kept flat
  because it doubles as the process-level health probe).
- Domain failures (child MCP error, unknown server/tool, timed-out child)
  answer HTTP 200 with `{"ok": false, "error": ...}` so the app can render the
  reason directly. Transport problems keep conventional status codes:
  `400` invalid JSON body, `401` bad token, `404` unknown route/server,
  `500` unexpected handler exception (still in the envelope).

## Tool naming

Each bridge tool is named `<serverId>.<toolName>` where `serverId` is the
identifier from the bridge config and `toolName` is the stdio server's own
tool name, e.g. `filesys.read_file`. The `/list_tools` catalog echoes the
split parts so clients can call without re-parsing:

```json
{
  "name": "filesys.read_file",
  "server": "filesys",
  "serverName": "Filesystem MCP",
  "tool": "read_file",
  "description": "Read a file…",
  "inputSchema": { "type": "object", "properties": { "path": { "type": "string" } } }
}
```

`inputSchema` is passed through verbatim from the stdio server, so the app can
build OpenAI function-calling definitions without knowledge of the tool.

On the client side (`BridgeToolRegistry`) tools surface as `ToolSpec`s whose
ids are OpenAI-safe (`bridge_<server>_<tool>` with non-alphanumerics
collapsed), because `.` is not a legal OpenAI function name character.

## POST /list_tools

Request body is ignored (empty `{}` is fine).

```json
{"ok": true, "payload": {"tools": [ {"name": "a.echo", "server": "a", ...}, ... ]}}
```

Servers that failed their handshake simply contribute no tools; the catalog is
the union over all live servers.

## POST /call_tool

Request body:

```json
{"server": "filesys", "tool": "read_file", "arguments": {"path": "a.txt"}}
```

- `server` — must match a configured `id`; unknown ids answer
  `404 {"ok": false, "error": "unknown server: filesys"}`.
- `tool` — the stdio server's tool name (no prefix).
- `arguments` — optional object, forwarded as-is as the JSON-RPC params.

The bridge translates this into a JSON-RPC `tools/call` over the child's
stdio, awaits the response (matching by request id), and unwraps:

```json
{"ok": true, "payload": {"content": [{"type": "text", "text": "…"}]}}
```

If the child answers a JSON-RPC error or `isError: true`, the text content is
extracted and returned as `{"ok": false, "error": "<text>"}`.

## GET /health

```json
{
  "ok": true,
  "servers": [
    {"id": "filesys", "name": "Filesystem MCP", "alive": true, "toolCount": 7},
    {"id": "git", "name": "Git MCP", "alive": false, "toolCount": 0}
  ]
}
```

`alive` reflects the current child process state; `toolCount` is the size of
the cached catalog (0 until a handshake succeeds).

## Child process lifecycle (server side)

- On `start()` every configured stdio server is spawned via `Process.start`
  and taken through a minimal handshake over line-delimited JSON on
  stdin/stdout: `initialize` → `notifications/initialized` → `tools/list`.
  The `tools/list` result is cached per server.
- When a child dies the bridge schedules a best-effort respawn with
  exponential backoff (`base · 2^failures`, capped), then redoes the
  handshake to refresh the catalog. Backoff resets once a spawn is stable or
  a handshake succeeds.
- `stop()` kills every child and closes the HTTP listener.

## Client timeouts

`BridgeToolRegistry` applies a 5 s timeout to `/list_tools` and a 30 s timeout
to `/call_tool`. Both surface as `BridgeException` with a readable message,
as do 401 responses and network failures.
