# em_disco
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

em_disco is the WebSocket bus and query dispatcher of the [Emergence](https://github.com/EmergenceSystem)
distributed discovery network.

![Screenshot](https://github.com/EmergenceSystem/em_disco/blob/main/em_disco.png)

---

## Philosophy

em_disco is the shared bus of the Emergence distributed discovery network. Agents —
filters, crawlers, knowledge bases — connect once over a persistent WebSocket and receive
every query broadcast to them. HTTP clients post a query and receive aggregated results
from all responding agents. There is no central index: results come live from agents as
they respond.

Any node that speaks the WebSocket protocol can be an agent. em_disco routes — it does
not store, rank, or synthesise.

---

## Architecture

```
HTTP client / Emquest / MCP client
        │
        ▼
   em_disco :8080
    ├── POST /query              → broadcast + collect results
    ├── GET  /ws                 → persistent WebSocket bus
    ├── GET  /registry           → live agent list (JSON)
    ├── GET  /registry/events    → live agent list (SSE push)
    └── GET+POST /mcp            → MCP Streamable HTTP transport
        │
        ▼  WebSocket push
  connected agents
    ├──▶ dns_filter
    ├──▶ web_filter
    ├──▶ atom_filter
    └──▶ … any em_agent
```

---

## Features

- **WebSocket bus** — agents hold a persistent connection; queries are pushed to them,
  results returned asynchronously
- **HTTP query dispatch** — `POST /query` fans out to all agents and returns aggregated
  results
- **Capability routing** — route queries to agents matching a capability set, with
  automatic broadcast fallback
- **Live agent registry** — `GET /registry` (JSON snapshot) and `GET /registry/events`
  (SSE push on connect/disconnect)
- **MCP endpoint** — `GET/POST /mcp` implements MCP Streamable HTTP transport
  (spec 2025-03-26); compatible with Claude, Cursor, VS Code
- **JWT authentication** — optional; agents present a `?token=…` query parameter on
  WebSocket upgrade
- **Token-bucket rate limiting** — per-IP, localhost gets an effectively unlimited rate

---

## Requirements

- Erlang/OTP 27+
- [rebar3](https://rebar3.org)
- At least one agent implementing the
  [em_filter](https://github.com/EmergenceSystem/em_filter) contract

---

## Installation

```bash
git clone https://github.com/EmergenceSystem/em_disco
cd em_disco
rebar3 compile
rebar3 shell
```

---

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `port` | `8080` | HTTP listen port (also `EM_DISCO_PORT` env var) |
| `require_auth` | `false` | Require JWT on WebSocket connections — **enable in production** |
| `jwt_secret` | `"changeme"` | HS256 signing secret — **change in production** |
| `ws_idle_timeout` | `60000` | WebSocket idle timeout in ms |
| `query_timeout_ms` | `5000` | Max wait for agent results per query |
| `rate_limit_per_second` | `10` | Token refill rate for remote IPs (req/s) |
| `rate_limit_burst` | `30` | Burst capacity for remote IPs |
| `rate_limit_localhost` | `1000` | Effective unlimited for localhost |

Keys go in `sys.config` under the `em_disco` key:

```erlang
[{em_disco, [
    {port, 8080},
    {require_auth, false},
    {jwt_secret, <<"my-secret">>}
]}].
```

---

## HTTP API

### POST /query

Submit a query and receive aggregated results from all connected agents.

```bash
curl -X POST http://localhost:8080/query \
     -H "content-type: application/json" \
     -d '{"query": "erlang otp"}'
```

Accepts both `"query"` and `"value"` field names for the search term. Optionally
route only to agents with specific capabilities:

```json
{"query": "erlang otp", "capabilities": ["web", "rss"]}
```

Response:

```json
{"embryo_list": [
  {"type": "url", "properties": {"title": "...", "url": "...", "resume": "..."}},
  {"type": "dns", "properties": {"domain": "...", "ips": ["..."]}}
]}
```

### GET /registry

List all agents that completed the full handshake (`register` + `agent_hello`).

```bash
curl http://localhost:8080/registry
```

```json
{
  "agents": [
    {"name": "web_filter",  "capabilities": ["web"],           "connected_at": 1714000000},
    {"name": "dns_filter",  "capabilities": ["dns","network"], "connected_at": 1714000100}
  ]
}
```

Returns an empty `agents` list when no agents are connected. Plain filters (nodes that
never sent `agent_hello`) do not appear here.

### GET /registry/events

Server-Sent Events stream. Pushes the full agent list on every connect/disconnect event.
A `: ping` comment is sent every 30 s to keep the connection alive.

```bash
curl -N http://localhost:8080/registry/events
```

The browser's native `EventSource` API reconnects automatically on disconnect.

### GET /mcp + POST /mcp

MCP Streamable HTTP transport (spec 2025-03-26). Compatible with Claude, Cursor,
VS Code and any MCP-capable LLM client.

Available tools: `search`, `list_agents`, `list_capabilities`.

```bash
curl -X POST http://localhost:8080/mcp \
     -H "content-type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"erlang"}}}'
```

---

## WebSocket Protocol

All agents connect to `ws://localhost:8080/ws`.

If `require_auth` is `true` (default), pass a JWT in the query string:

```
ws://localhost:8080/ws?token=<jwt>
```

### Handshake (required order)

**Step 1 — register** (all nodes):
```json
{"action": "register", "name": "my_filter"}
```
Response:
```json
{"status": "ok", "action": "registered"}
```

**Step 2 — agent_hello** (agents only; omit for plain filters):
```json
{"action": "agent_hello", "capabilities": ["web", "search"]}
```
Response:
```json
{"status": "ok", "action": "agent_registered", "capabilities": ["web", "search"]}
```

Only agents that complete both steps are visible in the registry and eligible to receive
queries.

### Query → Result

Disco broadcasts a query to all eligible agents:
```json
{"action": "query", "id": "<query_id>", "body": "search term"}
```

Agent responds:
```json
{"action": "result", "id": "<query_id>", "data": <result>}
```

Multiple agents may respond to the same `id`. Results are collected until all agents
respond or `query_timeout_ms` fires.

---

## Authentication

JWT is optional — set `{require_auth, false}` in sys.config for local development.

When enabled, issue a token from the Erlang shell:

```erlang
Secret = application:get_env(em_disco, jwt_secret, <<"changeme">>),
Token = em_disco_auth:issue(<<"my_agent">>, Secret).
```

Agents pass the token as a query parameter:

```
ws://localhost:8080/ws?token=<jwt>
```

Tokens are valid for 24 hours. The `sub` claim must match the `name` field sent in the
`register` frame.

---

## Project Structure

```
src/
  em_disco.erl                         — core API: query/1,2, list_agents/0, list_capabilities/0
  em_disco_app.erl                     — OTP application callback
  em_disco_sup.erl                     — top-level supervisor, ETS init, Cowboy listener
  em_disco_handlers.erl                — WebSocket handler (registration, query dispatch)
  em_disco_http_handler.erl            — POST /query HTTP handler
  em_disco_auth.erl                    — JWT issuance and verification (HS256)
  em_disco_rate.erl                    — token-bucket rate limiter (ETS hot path + gen_server sweep)
  em_disco_registry_handler.erl        — GET /registry HTTP handler
  em_disco_registry_events_handler.erl — GET /registry/events SSE handler
  em_disco_sse_registry.erl            — SSE broadcaster gen_server
  em_disco_mcp_handler.erl             — GET/POST /mcp MCP Streamable HTTP handler
  jose_json_otp.erl                    — JOSE JSON adapter for OTP's built-in json module
```

---

## Related

- [em_filter](https://github.com/EmergenceSystem/em_filter) — library for building filters and agents
- [Emquest](https://github.com/EmergenceSystem/Emquest) — web gateway client
- [EmPy](https://github.com/EmergenceSystem/EmPy) — standalone Python CLI client

---

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
