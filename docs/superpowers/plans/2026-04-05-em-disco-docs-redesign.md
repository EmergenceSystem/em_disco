# em_disco Documentation Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite README and add EDoc across all 11 em_disco source files to prepare the project for public release — English throughout, consistent with the Emquest documentation pass.

**Architecture:** Documentation-only pass — no logic changes. README communicates the bus philosophy and all interfaces. EDoc on every exported function and key private functions gives contributors everything they need. `jose_json_otp.erl` is excluded (third-party adapter).

**Tech Stack:** Erlang/OTP 27, EDoc, rebar3, Markdown

---

## Files Modified

| File | Change |
|------|--------|
| `README.md` | Full rewrite — philosophy, architecture, all endpoints, auth, config |
| `src/em_disco_app.erl` | Drop `@author`, remove `@param`/`@return`, tighten @doc |
| `src/em_disco.erl` | Enrich module doc, add @doc on 3 private functions |
| `src/em_disco_sup.erl` | Drop `@author`, enrich module doc with ETS table list |
| `src/em_disco_http_handler.erl` | Drop `@author`, add @doc on 2 private helpers |
| `src/em_disco_auth.erl` | Enrich module doc, add @doc on `check_expiry/1` |
| `src/em_disco_rate.erl` | Enrich module doc, add @doc on 4 private helpers + sweep comment |
| `src/em_disco_mcp_handler.erl` | Drop `@author`, add @doc on 7 private helpers |
| `src/em_disco_registry_handler.erl` | Drop `@author` |

---

## Task 1: Rewrite README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace README with updated content**

Write the following complete content to `README.md`:

```markdown
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
| `require_auth` | `true` | Require JWT on WebSocket connections |
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
```

- [ ] **Step 2: Commit**

```bash
cd C:/Users/steve/dev/search/EmergenceSystem/em_disco
rtk git add README.md
rtk git commit -m "docs: rewrite README — philosophy, all endpoints, auth, config, project structure"
```

---

## Task 2: Document `em_disco_app.erl`

**Files:**
- Modify: `src/em_disco_app.erl`

- [ ] **Step 1: Replace module header and function docs**

Replace the entire file header and function doc blocks. The application logic is unchanged.

Replace the module-level block:

```erlang
%%%-------------------------------------------------------------------
%%% @doc em_disco OTP application callback module.
%%%
%%% Entry point for the em_disco application. Delegates startup to
%%% {@link em_disco_sup}, which initialises ETS tables and starts the
%%% Cowboy HTTP/WebSocket listener.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_app).
-behaviour(application).

-export([start/2, stop/1]).
```

Replace the `start/2` doc block:

```erlang
%%--------------------------------------------------------------------
%% @doc Start the em_disco application.
%%
%% Called automatically by the OTP application controller.
%% Delegates to {@link em_disco_sup:start_link/0}.
%% @end
%%--------------------------------------------------------------------
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
```

Replace the `stop/1` doc block:

```erlang
%%--------------------------------------------------------------------
%% @doc Stop the em_disco application.
%%
%% Stops the Cowboy listener. Called automatically by the OTP
%% application controller after the supervision tree has been shut down.
%% @end
%%--------------------------------------------------------------------
-spec stop(term()) -> ok.
```

- [ ] **Step 2: Verify compilation**

```bash
cd C:/Users/steve/dev/search/EmergenceSystem/em_disco
rebar3 compile
```

Expected: no errors or warnings on `em_disco_app.erl`.

- [ ] **Step 3: Commit**

```bash
rtk git add src/em_disco_app.erl
rtk git commit -m "docs: clean up EDoc in em_disco_app — drop @author, remove @param/@return"
```

---

## Task 3: Document `em_disco.erl`

**Files:**
- Modify: `src/em_disco.erl`

- [ ] **Step 1: Replace module header**

Replace the opening block (lines 1–11):

```erlang
%%%-------------------------------------------------------------------
%%% @doc em_disco core API — query dispatch and agent registry inspection.
%%%
%%% Provides two groups of functions:
%%%
%%% === Query dispatch ===
%%%
%%% {@link query/1} and {@link query/2} fan out a query to all connected
%%% agents, collect results within a configurable deadline, and return
%%% the aggregated list. Agents respond asynchronously; the calling
%%% process blocks until all agents reply or the deadline expires.
%%%
%%% ETS tables used:
%%% <ul>
%%%   <li>`agent_registry'  — `{Name, Caps, ConnectedAt, Pid}' tuples,
%%%       maintained by {@link em_disco_handlers}</li>
%%%   <li>`pending_queries' — `{QueryId, CallerPid}' entries for
%%%       in-flight queries, owned by this module</li>
%%% </ul>
%%%
%%% === Registry inspection ===
%%%
%%% {@link list_agents/0} and {@link list_capabilities/0} read
%%% `agent_registry' directly — safe to call from any process.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco).
```

- [ ] **Step 2: Add `@doc` to `collect_results/4`**

Replace the existing `%% @private` comment above `collect_results/4`:

```erlang
%% @private
%% @doc Collect query results from N agents until all respond or the deadline passes.
%%
%% `Deadline' is an absolute `erlang:monotonic_time(millisecond)' value
%% shared across all agents — a single global deadline, not per-agent.
%% Results that arrive before the deadline are accumulated in `Acc'.
%% If the deadline fires with agents still pending, a warning is logged
%% and the partial result is returned.
%% @end
collect_results(0, Id, _Deadline, Acc) ->
```

- [ ] **Step 3: Add `@doc` to `select_agents/2`**

Replace the existing `%% @private` above `select_agents/2`:

```erlang
%% @private
%% @doc Filter agents by capability set.
%%
%% Returns all agents whose capability list overlaps with `Caps'.
%% An empty `Caps' list returns all agents (broadcast).
%% If `Caps' is non-empty but no agent matches, falls back to broadcast
%% so the query is never silently dropped.
%% @end
-spec select_agents(list(), [binary()]) -> list().
```

- [ ] **Step 4: Add `@doc` to `generate_query_id/0`**

Replace the existing `%% @private` above `generate_query_id/0`:

```erlang
%% @private
%% @doc Generate a random 8-byte base64 query ID.
%%
%% Used to correlate agent responses with the originating query.
%% Collision probability is negligible at typical query rates.
%% @end
-spec generate_query_id() -> binary().
```

- [ ] **Step 5: Verify compilation**

```bash
rebar3 compile
```

Expected: no errors or warnings on `em_disco.erl`.

- [ ] **Step 6: Commit**

```bash
rtk git add src/em_disco.erl
rtk git commit -m "docs: enrich EDoc in em_disco — module overview, collect_results/select_agents/generate_query_id @doc"
```

---

## Task 4: Document `em_disco_sup.erl`

**Files:**
- Modify: `src/em_disco_sup.erl`

- [ ] **Step 1: Replace module header**

Replace the opening block (lines 1–17):

```erlang
%%%-------------------------------------------------------------------
%%% @doc em_disco top-level supervisor.
%%%
%%% Initialises three ETS tables shared across the application:
%%% <ul>
%%%   <li>`agent_registry'  — connected agents, maintained by
%%%       {@link em_disco_handlers}</li>
%%%   <li>`pending_queries' — in-flight query correlations, maintained
%%%       by {@link em_disco}</li>
%%%   <li>`rate_buckets'    — per-IP token buckets, maintained by
%%%       {@link em_disco_rate}</li>
%%% </ul>
%%%
%%% Starts the Cowboy HTTP listener on the configured port and
%%% supervises two workers: {@link em_disco_sse_registry} and
%%% {@link em_disco_rate}.
%%%
%%% === HTTP routes (default port 8080) ===
%%%
%%%   GET  /                   → index.html landing page (registry UI)
%%%   GET  /ws                 → em_disco_handlers (WebSocket, agents)
%%%   POST /query              → em_disco_http_handler (HTTP queries)
%%%   GET  /registry           → em_disco_registry_handler (agent list JSON)
%%%   GET  /registry/events    → em_disco_registry_events_handler (SSE push)
%%%   GET  /mcp, POST /mcp     → em_disco_mcp_handler (MCP Streamable HTTP)
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_sup).
-behaviour(supervisor).
```

- [ ] **Step 2: Verify compilation**

```bash
rebar3 compile
```

Expected: no errors or warnings on `em_disco_sup.erl`.

- [ ] **Step 3: Commit**

```bash
rtk git add src/em_disco_sup.erl
rtk git commit -m "docs: enrich EDoc in em_disco_sup — ETS table list, full route table"
```

---

## Task 5: Document `em_disco_http_handler.erl`

**Files:**
- Modify: `src/em_disco_http_handler.erl`

- [ ] **Step 1: Drop `@author` from module header**

Replace the opening block (lines 1–23):

```erlang
%%%-------------------------------------------------------------------
%%% @doc HTTP handler for `POST /query'.
%%%
%%% Checks the rate limit for the caller's IP, parses the JSON body,
%%% dispatches the query via `em_disco:query/2', and returns the
%%% flattened, type-sorted embryo list as JSON.
%%%
%%% === Request format ===
%%%
%%%   { "value": "<query>" }
%%%   { "query": "<query>" }
%%%   { "query": "<query>", "capabilities": ["dns", "rss"] }
%%%
%%% When "capabilities" is present and non-empty, only agents that
%%% advertised at least one of those capabilities receive the query.
%%% Omit "capabilities" (or pass []) for broadcast to all agents.
%%%
%%% === Response format ===
%%%
%%%   { "embryo_list": [ <result>, ... ] }
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_http_handler).
-behaviour(cowboy_handler).
```

- [ ] **Step 2: Add `@doc` to `parse_query_body/1`**

Replace the existing `%% @private` above `parse_query_body/1`:

```erlang
%% @private
%% @doc Parse a JSON POST body into a query binary and capabilities list.
%%
%% Accepts both `"query"' and `"value"' field names for backwards
%% compatibility with em_filter clients. The `"capabilities"' field is
%% optional; if absent or `[]', returns `[]' (broadcast to all agents).
%%
%% Returns `{error, empty_query}' if the query string is empty,
%% `{error, invalid_json}' if the body cannot be decoded.
%% @end
-spec parse_query_body(binary()) ->
    {ok, binary(), [binary()]} | {error, atom()}.
```

- [ ] **Step 3: Add `@doc` to `sort_by_type_frequency/1`**

Replace the existing `%% @private` above `sort_by_type_frequency/1`:

```erlang
%% @private
%% @doc Sort results by type frequency — most-common type first.
%%
%% Groups items by their `"type"' field then orders the groups by
%% descending count. Within each group, insertion order is preserved.
%% Items without a `"type"' field are grouped under `<<>>' (empty binary).
%% @end
-spec sort_by_type_frequency([map()]) -> [map()].
```

- [ ] **Step 4: Verify compilation**

```bash
rebar3 compile
```

Expected: no errors or warnings on `em_disco_http_handler.erl`.

- [ ] **Step 5: Commit**

```bash
rtk git add src/em_disco_http_handler.erl
rtk git commit -m "docs: add EDoc to em_disco_http_handler — parse_query_body, sort_by_type_frequency"
```

---

## Task 6: Document `em_disco_auth.erl`

**Files:**
- Modify: `src/em_disco_auth.erl`

- [ ] **Step 1: Replace module header**

Replace the opening block (lines 1–9):

```erlang
%%%-------------------------------------------------------------------
%%% @doc JWT authentication for em_disco WebSocket connections.
%%%
%%% Provides HS256 (HMAC-SHA256) token issuance and verification.
%%%
%%% === Token shape ===
%%%
%%%   `sub'  — agent name (must match the `register' frame name)
%%%   `iat'  — issued-at timestamp (Unix seconds)
%%%   `exp'  — expiry timestamp (iat + 86400 s, i.e. 24 hours)
%%%
%%% === Configuration ===
%%%
%%%   `jwt_secret' — application env key; defaults to `<<"changeme">>'.
%%%   <strong>Change this in production.</strong>
%%%
%%% Authentication can be disabled with `{require_auth, false}' in
%%% sys.config — useful for local development.
%%%
%%% Issue a token from the Erlang shell:
%%% ```
%%% Secret = application:get_env(em_disco, jwt_secret, <<"changeme">>),
%%% Token  = em_disco_auth:issue(<<"my_agent">>, Secret).
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_auth).
```

- [ ] **Step 2: Add `@doc` to `check_expiry/1`**

Replace the existing `%% @private` above `check_expiry/1`:

```erlang
%% @private
%% @doc Return `{ok, Claims}' if the token's `exp' claim is in the future.
%%
%% Returns `{error, expired}' if the current Unix time is greater than
%% or equal to the `exp' field. A missing `exp' field defaults to `0'
%% and is treated as expired.
%% @end
-spec check_expiry(map()) -> {ok, map()} | {error, expired}.
```

- [ ] **Step 3: Verify compilation**

```bash
rebar3 compile
```

Expected: no errors or warnings on `em_disco_auth.erl`.

- [ ] **Step 4: Commit**

```bash
rtk git add src/em_disco_auth.erl
rtk git commit -m "docs: enrich EDoc in em_disco_auth — token shape, config, check_expiry @doc"
```

---

## Task 7: Document `em_disco_rate.erl`

**Files:**
- Modify: `src/em_disco_rate.erl`

- [ ] **Step 1: Replace module header**

Replace the opening block (lines 1–10):

```erlang
%%%-------------------------------------------------------------------
%%% @doc Token-bucket rate limiter for em_disco HTTP endpoints.
%%%
%%% The hot path (`check/1') reads and writes the `rate_buckets' ETS
%%% table directly — no gen_server call on the request path. The
%%% gen_server handles only periodic cleanup of stale entries.
%%%
%%% === Configuration ===
%%%
%%%   `rate_limit_per_second' — token refill rate for remote IPs
%%%                             (default: 10 req/s)
%%%   `rate_limit_burst'      — burst capacity for remote IPs
%%%                             (default: 30 tokens)
%%%   `rate_limit_localhost'  — effective rate and burst for localhost
%%%                             (default: 1000)
%%%
%%% Localhost (`127.0.0.1' / `::1') gets a separate, much higher limit
%%% so that local tooling is never rate-limited.
%%%
%%% Stale bucket entries (not updated in the last 5 minutes) are
%%% purged every 60 seconds by the gen_server sweep.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_rate).
-behaviour(gen_server).
```

- [ ] **Step 2: Add sweep comment to `handle_info/2`**

Replace the `handle_info(sweep, ...)` clause header:

```erlang
%% Periodic sweep — remove entries idle for more than ENTRY_TTL_MS (5 min).
handle_info(sweep, State) ->
```

- [ ] **Step 3: Add `@doc` to private helpers**

Replace the four `%% @private` blocks above the private functions:

```erlang
%% @private
%% @doc Returns the token refill rate (req/s) for the given IP.
%%
%% Localhost gets `rate_limit_localhost'; all other IPs get
%% `rate_limit_per_second'.
%% @end
-spec rate_for_ip(tuple()) -> number().
```

```erlang
%% @private
%% @doc Returns the burst capacity for the given IP.
%%
%% Localhost gets `rate_limit_localhost'; all other IPs get
%% `rate_limit_burst'.
%% @end
-spec burst_for_ip(tuple()) -> number().
```

```erlang
%% @private
%% @doc Returns `true' for `127.0.0.1' (IPv4) and `::1' (IPv6) loopback addresses.
%% @end
-spec is_localhost(tuple()) -> boolean().
```

```erlang
%% @private
%% @doc Coerce an integer or float to float for bucket arithmetic.
%% @end
-spec to_float(number()) -> float().
```

- [ ] **Step 4: Verify compilation**

```bash
rebar3 compile
```

Expected: no errors or warnings on `em_disco_rate.erl`.

- [ ] **Step 5: Commit**

```bash
rtk git add src/em_disco_rate.erl
rtk git commit -m "docs: enrich EDoc in em_disco_rate — module overview, private helpers @doc, sweep comment"
```

---

## Task 8: Document `em_disco_mcp_handler.erl`

**Files:**
- Modify: `src/em_disco_mcp_handler.erl`

- [ ] **Step 1: Drop `@author` from module header**

Replace the opening block (lines 1–45):

```erlang
%%%-------------------------------------------------------------------
%%% @doc MCP Streamable HTTP handler for em_disco.
%%%
%%% Implements the Model Context Protocol (MCP) Streamable HTTP
%%% transport (spec 2025-03-26) on a single `/mcp' endpoint.
%%%
%%% Compatible with Claude, OpenAI, Cursor, VS Code and any other
%%% MCP-capable LLM client.
%%%
%%% === Transport ===
%%%
%%%   POST /mcp  Content-Type: application/json
%%%     → single JSON-RPC response   (Accept: application/json)
%%%     → SSE stream                  (Accept: text/event-stream)
%%%
%%%   GET  /mcp
%%%     → SSE stream for server-initiated notifications (optional,
%%%       not required by most clients)
%%%
%%% === JSON-RPC methods exposed ===
%%%
%%%   initialize        → server info + capabilities declaration
%%%   notifications/initialized → ack (no-op)
%%%   tools/list        → list of available tools
%%%   tools/call        → invoke a tool
%%%
%%% === Tools ===
%%%
%%%   search(query, capabilities?)
%%%       Runs a query against connected Emergence agents.
%%%       `capabilities': optional array of strings to route only to
%%%       matching agents. Omit for broadcast to all agents.
%%%
%%%   list_agents()
%%%       Returns all currently connected agents with their name,
%%%       capabilities and connection timestamp.
%%%
%%%   list_capabilities()
%%%       Returns the deduplicated list of all capabilities currently
%%%       offered by connected agents.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_mcp_handler).
-behaviour(cowboy_handler).
```

- [ ] **Step 2: Add `@doc` to `handle/3` GET**

Replace the `%% @private\n%% GET /mcp` comment above the GET clause:

```erlang
%% @private
%% @doc Open an SSE stream and send the `endpoint' event.
%%
%% Required by the MCP Streamable HTTP spec to announce the POST
%% endpoint to the client. The stream is closed immediately after —
%% clients POST their JSON-RPC requests separately.
%% @end
handle(<<"GET">>, Req0, State) ->
```

- [ ] **Step 3: Add `@doc` to `handle/3` POST**

Replace the `%% POST /mcp` comment above the POST clause:

```erlang
%% @private
%% @doc Parse the JSON-RPC body and dispatch.
%%
%% Checks the `Accept' header to decide the response mode: plain JSON
%% (`application/json') or SSE (`text/event-stream'). Batch requests
%% (JSON arrays) always use plain JSON regardless of `Accept'.
%% @end
handle(<<"POST">>, Req0, State) ->
```

- [ ] **Step 4: Add `@doc` to `handle_json/3`, `handle_sse/3`, `reply_json/3`**

Replace the three `%% @private` comment lines above each helper:

```erlang
%% @private
%% @doc Dispatch a single JSON-RPC request and reply with plain JSON.
%% @end
handle_json(Request, Req0, State) ->
```

```erlang
%% @private
%% @doc Dispatch a single JSON-RPC request and stream the response as
%% a single SSE `message' event.
%% @end
handle_sse(Request, Req0, State) ->
```

```erlang
%% @private
%% @doc Send a 200 JSON response with CORS headers.
%% @end
reply_json(Body, Req0, State) ->
```

- [ ] **Step 5: Add `@doc` to `tools_schema/0`, `send_sse/3`, `cors_headers/0`**

```erlang
%% @private
%% @doc Return the MCP tool definitions for `search', `list_agents',
%% and `list_capabilities'.
%% @end
tools_schema() ->
```

```erlang
%% @private
%% @doc Write a single `event: Event\ndata: Data\n\n' frame to the stream.
%% @end
send_sse(Req, Event, Data) ->
```

```erlang
%% @private
%% @doc Return CORS headers allowing all origins, GET/POST/OPTIONS
%% methods, and content-type/accept/authorization request headers.
%% @end
cors_headers() ->
```

- [ ] **Step 6: Verify compilation**

```bash
rebar3 compile
```

Expected: no errors or warnings on `em_disco_mcp_handler.erl`.

- [ ] **Step 7: Commit**

```bash
rtk git add src/em_disco_mcp_handler.erl
rtk git commit -m "docs: add EDoc to em_disco_mcp_handler — drop @author, @doc on all helpers"
```

---

## Task 9: Drop `@author` from remaining files

**Files:**
- Modify: `src/em_disco_registry_handler.erl`
- Modify: `src/em_disco_handlers.erl`

`em_disco_sse_registry.erl` and `em_disco_registry_events_handler.erl` have no
`@author` tag — skip them.

- [ ] **Step 1: Remove `@author Steve Roques` from `em_disco_registry_handler.erl`**

In `em_disco_registry_handler.erl`, replace:

```erlang
%%% @author Steve Roques
%%% @end
```

with:

```erlang
%%% @end
```

- [ ] **Step 2: Remove `@author Steve Roques` from `em_disco_handlers.erl`**

In `em_disco_handlers.erl`, replace:

```erlang
%%% @author Steve Roques
%%% @end
```

with:

```erlang
%%% @end
```

- [ ] **Step 3: Verify compilation**

```bash
rebar3 compile
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
rtk git add src/em_disco_registry_handler.erl src/em_disco_handlers.erl
rtk git commit -m "docs: drop @author tags from em_disco_registry_handler and em_disco_handlers"
```

---

## Self-Review

**Spec coverage:**
- ✅ README — philosophy, architecture diagram, features, requirements, installation,
  full config table, all 4 HTTP endpoints, WebSocket protocol, authentication, project
  structure, related projects, license
- ✅ `em_disco_app.erl` — `@author` dropped, `@param`/`@return` removed, @doc tightened
- ✅ `em_disco.erl` — module doc enriched, `@doc` on `collect_results/4`,
  `select_agents/2`, `generate_query_id/0`
- ✅ `em_disco_sup.erl` — `@author` dropped, module doc with ETS table list and full
  route table
- ✅ `em_disco_http_handler.erl` — `@author` dropped, `@doc` on `parse_query_body/1`
  and `sort_by_type_frequency/1`
- ✅ `em_disco_auth.erl` — module doc enriched, `@doc` on `check_expiry/1`
- ✅ `em_disco_rate.erl` — module doc enriched, `@doc` on 4 private helpers,
  sweep comment
- ✅ `em_disco_mcp_handler.erl` — `@author` dropped, `@doc` on 7 helpers
- ✅ `em_disco_registry_handler.erl` and `em_disco_handlers.erl` — `@author` dropped
- ✅ `em_disco_sse_registry.erl`, `em_disco_registry_events_handler.erl` — already good,
  no `@author` present
- ✅ `jose_json_otp.erl` — explicitly excluded

**Placeholder scan:** None found. All doc blocks contain actual content.

**Type consistency:** No new types introduced — documentation only. All `-spec`
declarations in the plan match the existing signatures in the source files.
