# em_disco — Documentation & README Redesign

**Date:** 2026-04-05
**Status:** Approved
**Scope:** Code documentation (EDoc), README rewrite — English, public-facing

---

## Context

em_disco is the central bus of the Emergence distributed discovery network. The project
is being opened to the public alongside Emquest. Documentation must convey the
architecture clearly — the role of the bus, how agents connect over WebSocket, how HTTP
clients query it, and the optional MCP interface.

Language: **English throughout** (README and all EDoc).
Style: consistent with the Emquest documentation pass — EDoc `@doc`, `@spec` on all
exported functions; key private functions get `%% @private` + `@doc` on non-obvious
logic; no `@author` tags; no `@param`/`@return` style.

---

## Philosophy (to communicate consistently)

> em_disco is the shared bus of the Emergence distributed discovery network. Agents —
> filters, crawlers, knowledge bases — connect once over a persistent WebSocket and
> receive every query broadcast to them. HTTP clients post a query and receive aggregated
> results from all responding agents. There is no central index: results come live from
> agents as they respond.

Key ideas to echo:
- **Shared bus, not a server** — any node can be an agent; em_disco routes, not stores
- **WebSocket-first** — agents hold a persistent connection; queries are pushed to them
- **Heterogeneous agents** — web, DNS, RSS, LLM, anything — same protocol
- **MCP-compatible** — LLM clients (Claude, Cursor, VS Code) can query via MCP
- **Live registry** — agent presence is tracked in ETS and streamed via SSE

---

## 1. README Rewrite

Write a new `README.md` with the following sections. All content in English.

### Header
```markdown
# em_disco
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)
```
One-line description: _"The WebSocket bus and query dispatcher of the Emergence
distributed discovery network."_

### Philosophy
Short section (3–4 sentences) using the philosophy above. Emphasise: no central index,
agents connect once and receive queries pushed to them, HTTP clients get aggregated
results.

### Architecture
ASCII diagram showing:
```
HTTP client / Emquest / MCP client
        │
        ▼
   em_disco :8080
    ├── POST /query       → broadcast + collect results
    ├── GET  /ws          → persistent WebSocket bus
    ├── GET  /registry    → live agent list (JSON)
    ├── GET  /registry/events → live agent list (SSE push)
    └── GET+POST /mcp     → MCP Streamable HTTP transport
        │
        ▼  WebSocket (push)
  connected agents
    ├──▶ dns_filter
    ├──▶ web_filter
    ├──▶ atom_filter
    └──▶ … any em_agent
```

### Features
Bullet list:
- **WebSocket bus** — agents hold a persistent connection; queries are pushed, results returned asynchronously
- **HTTP query dispatch** — `POST /query` fans out to all agents and returns aggregated results
- **Capability routing** — route queries to agents matching a specific capability set, with broadcast fallback
- **Live agent registry** — `GET /registry` (JSON snapshot) and `GET /registry/events` (SSE push on connect/disconnect)
- **MCP endpoint** — `GET/POST /mcp` implements MCP Streamable HTTP transport; compatible with Claude, Cursor, VS Code
- **JWT authentication** — optional; agents present a `?token=…` query parameter on WebSocket upgrade
- **Token-bucket rate limiting** — per-IP, localhost gets a much higher limit; no gen_server call on the hot path

### Requirements
- Erlang/OTP 27+
- rebar3
- At least one agent implementing the [em_filter](https://github.com/EmergenceSystem/em_filter) contract

### Installation
```bash
git clone https://github.com/EmergenceSystem/em_disco
cd em_disco
rebar3 compile
rebar3 shell
```

### Configuration
Table of all knobs:

| Key | Default | Description |
|-----|---------|-------------|
| `port` | `8080` | HTTP listen port (also `EM_DISCO_PORT` env var) |
| `require_auth` | `true` | Require JWT on WebSocket connections |
| `jwt_secret` | `"changeme"` | HS256 signing secret — **change in production** |
| `ws_idle_timeout` | `60000` | WebSocket idle timeout in ms |
| `query_timeout_ms` | `5000` | Max wait for agent results per query |
| `rate_limit_per_second` | `10` | Token refill rate for remote IPs (req/s) |
| `rate_limit_burst` | `30` | Max burst for remote IPs |
| `rate_limit_localhost` | `1000` | Effective unlimited for localhost |

Config goes in `sys.config` under the `em_disco` key, or via environment variables
where supported.

### HTTP API

#### POST /query
Request + response example (JSON). Show both `"query"` and `"value"` field forms.
Show optional `"capabilities"` field. Show the `embryo_list` response shape.

#### GET /registry
Response shape with `agents` array (name, capabilities, connected_at).
Note: plain filters (never sent `agent_hello`) do not appear here.

#### GET /registry/events
SSE stream. Each event is the same JSON as `GET /registry`. Pushed on every
agent connect/disconnect. Heartbeat `: ping` every 30 s.

#### GET /mcp + POST /mcp
MCP Streamable HTTP transport (spec 2025-03-26). Supports `initialize`,
`tools/list`, `tools/call`. Tools: `search`, `list_agents`, `list_capabilities`.
Show a `curl` example for `tools/call search`.

### WebSocket Protocol
Full message table:

**Agent → Disco:**
```json
{ "action": "register",    "name": "<name>" }
{ "action": "agent_hello", "capabilities": ["cap1", "cap2"] }
{ "action": "result",      "id": "<query_id>", "data": <result> }
```

**Disco → Agent:**
```json
{ "status": "ok", "action": "registered" }
{ "status": "ok", "action": "agent_registered", "capabilities": [...] }
{ "action": "query", "id": "<query_id>", "body": "<query_body>" }
```

Handshake order: `register` must come before `agent_hello`. Only agents that have
completed both frames are visible in the registry and eligible to receive queries.

### Authentication
- JWT is optional (disable with `{require_auth, false}` in sys.config)
- Agents pass their token as `?token=<jwt>` in the WebSocket URL
- Issue tokens with `em_disco_auth:issue(AgentName, Secret)` from the Erlang shell
- For development: `{require_auth, false}` skips all auth checks

### Project Structure
```
src/
  em_disco.erl                      — core API: query/1,2, list_agents/0, list_capabilities/0
  em_disco_app.erl                  — OTP application callback
  em_disco_sup.erl                  — top-level supervisor, ETS init, Cowboy listener
  em_disco_handlers.erl             — WebSocket handler (agent registration, query dispatch)
  em_disco_http_handler.erl         — POST /query HTTP handler
  em_disco_auth.erl                 — JWT issuance and verification (HS256)
  em_disco_rate.erl                 — token-bucket rate limiter (ETS hot path + gen_server sweep)
  em_disco_registry_handler.erl     — GET /registry HTTP handler
  em_disco_registry_events_handler.erl — GET /registry/events SSE handler
  em_disco_sse_registry.erl         — SSE broadcaster gen_server
  em_disco_mcp_handler.erl          — GET/POST /mcp MCP Streamable HTTP handler
  jose_json_otp.erl                 — JOSE JSON adapter for OTP's built-in json module
```

### Related
- [em_filter](https://github.com/EmergenceSystem/em_filter) — library for building filters and agents
- [Emquest](https://github.com/EmergenceSystem/Emquest) — web gateway client
- [EmPy](https://github.com/EmergenceSystem/EmPy) — Python CLI client

### License
Apache 2.0

---

## 2. Code Documentation (EDoc)

Documentation language: **English throughout**.
Style: EDoc `@doc`, `@spec` on all exported functions. Key private functions get
`%% @private` + `@doc`. Drop `@author` tags. No `@param`/`@return` tags — types go
in `-spec`.

### `em_disco_app.erl`
- Drop `@author`
- Remove `@param`/`@return` from `start/2` — types already covered by `-spec`
- Simplify `start/2` @doc: "Starts the top-level supervisor. Called automatically by the OTP application controller."
- Simplify `stop/2` @doc: "Stops the Cowboy listener and the application."
- Update module doc: describe the role (OTP callback, delegates to em_disco_sup)

### `em_disco.erl`
- Update module doc: describe the ETS tables (`agent_registry`, `pending_queries`), the
  query flow (fan-out → deadline collect → return), and the two public API groups (query
  dispatch and registry inspection)
- `query/1`: @doc — "Broadcasts to all connected agents. Delegates to `query/2` with an
  empty capabilities list."
- `query/2`: @doc already good — verify accuracy, add note that empty `[]` = broadcast
- `collect_results/4` (@private): add @doc explaining the deadline mechanism — a single
  deadline covers all agents (not per-agent timeout), and the function returns whatever
  arrived before the deadline
- `select_agents/2` (@private): add @doc — "Filter agents by capability. Empty list →
  broadcast. If no agent matches, falls back to broadcast so the query is never silently
  dropped."
- `generate_query_id/0` (@private): add @doc — "Generate a random 8-byte base64 query
  ID used to correlate agent responses."

### `em_disco_sup.erl`
- Drop `@author`
- Module doc: update — mention the three ETS tables created here (`agent_registry`,
  `pending_queries`, `rate_buckets`) and note that Cowboy is started here, not in the app
- `get_port/0`: @doc already good — keep

### `em_disco_handlers.erl`
- Drop `@author`
- Module doc, `init/2`, `websocket_init/1`, `websocket_handle/2`, `websocket_info/2`,
  `terminate/3`: all already have good @doc — keep, no changes needed

### `em_disco_http_handler.erl`
- Drop `@author`
- `parse_query_body/1` (@private): add @doc — "Parse a JSON POST body into a query
  binary and an optional capabilities list. Accepts both `\"query\"` and `\"value\"`
  fields for backwards compatibility."
- `sort_by_type_frequency/1` (@private): add @doc — "Group results by type and sort
  groups by frequency (most-results type first). Preserves insertion order within each
  group."

### `em_disco_auth.erl`
- Module doc: enrich — describe the JWT shape (sub, iat, exp), mention `require_auth`
  config key, mention that `em_disco_auth:issue/2` can be called from the shell for
  development
- `check_expiry/1` (@private): add @doc — "Return `{ok, Claims}` if the token's `exp`
  claim is in the future, `{error, expired}` otherwise."

### `em_disco_rate.erl`
- Module doc: clean up — mention the two configurable knobs (`rate_limit_per_second`,
  `rate_limit_burst`), that localhost gets a separate higher limit, and that the gen_server
  only handles periodic cleanup (not the hot path)
- `rate_for_ip/1` (@private): add @doc — "Returns the token refill rate (req/s) for the
  given IP. Localhost gets `rate_limit_localhost`, others get `rate_limit_per_second`."
- `burst_for_ip/1` (@private): add @doc — "Returns the burst capacity for the given IP."
- `is_localhost/1` (@private): add @doc — "Returns `true` for `127.0.0.1` and `::1`."
- `to_float/1` (@private): add @doc — "Coerce integer or float to float for bucket arithmetic."
- `handle_info(sweep)` gen_server callback: add inline comment explaining the sweep —
  deletes ETS entries not updated in the last 5 minutes.

### `em_disco_mcp_handler.erl`
- Drop `@author`
- `handle/3` (GET): add @doc — "Open an SSE stream and send the `endpoint` event as
  required by the MCP Streamable HTTP spec."
- `handle/3` (POST): add @doc — "Parse the JSON-RPC body and dispatch to the correct
  handler. Supports both plain JSON and SSE response modes based on the `Accept` header."
- `handle_json/3` (@private): add @doc — "Dispatch and reply with a plain JSON response."
- `handle_sse/3` (@private): add @doc — "Dispatch and stream the response as a single
  SSE `message` event."
- `reply_json/3` (@private): add @doc — "Send a JSON 200 response with CORS headers."
- `tools_schema/0` (@private): add @doc — "Return the MCP tool definitions for `search`,
  `list_agents`, and `list_capabilities`."
- `send_sse/3` (@private): add @doc — "Write a single SSE event frame to the stream."
- `cors_headers/0` (@private): add @doc — "Return CORS headers allowing all origins,
  GET/POST/OPTIONS, and content-type/accept/authorization."

### `em_disco_registry_handler.erl`
- Drop `@author`
- `init/2`: @doc already accurate — keep

### `em_disco_sse_registry.erl`
- Already in good shape — no changes needed

### `em_disco_registry_events_handler.erl`
- Already in good shape — no changes needed

### `jose_json_otp.erl`
- Skip — third-party adapter, do not modify

---

## Spec Self-Review

- **Placeholders**: none
- **Contradictions**: none — config table is consistent with the code (`application:get_env` calls)
- **Scope**: focused single implementation plan; jose_json_otp.erl explicitly excluded
- **Ambiguity**: `em_disco_handlers.erl` is noted as already good — plan will verify and
  skip if no changes needed
