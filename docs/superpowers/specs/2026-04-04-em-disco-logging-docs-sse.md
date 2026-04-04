# em_disco — Logging Cleanup, EDoc Pass, SSE Registry Push

**Date:** 2026-04-04
**Status:** Approved
**Scope:** Console logging, EDoc documentation, live agent registry via SSE

---

## Context

em_disco is the discovery node of the Emergence distributed discovery network. Agents connect via WebSocket, register their capabilities, and receive broadcast queries. The project is being opened alongside emquest; documentation and operational clarity must match.

Three issues to address:
1. OTP startup noise floods the console — only query calls and result counts should appear
2. EDoc is incomplete — modules have stubs but lack `@spec`, full `@doc`, and private annotations
3. The connected-agents page polls `/registry` every 15 s — wasteful when agents rarely change

---

## 1. Logging Cleanup

### Goal
Console output limited to:
- `[em_disco] agent connected: <name>`
- `[em_disco] agent disconnected: <name>`
- `[em_disco] query: <text>`
- `[em_disco] <N> result(s) for: <text>`

### Changes

**`em_disco_app.erl` — `start/2`**
Add programmatic OTP progress filter before supervisor start:
```erlang
logger:add_primary_filter(no_progress,
    {fun logger_filters:progress/2, stop}),
```

**`config/sys.config`**
Raise `logger_level` from `info` to `notice`.
This silences the existing `logger:info("em_disco started")` calls in app and sup without touching them.

**`em_disco_http_handler.erl`**
In the query handling path, add:
```erlang
logger:notice("[em_disco] query: ~ts", [Query]),
```
After results are collected and flattened:
```erlang
logger:notice("[em_disco] ~p result(s) for: ~ts", [length(Results), Query]),
```

**`em_disco_handlers.erl`**
After successful agent registration (post `agent_hello`):
```erlang
logger:notice("[em_disco] agent connected: ~ts", [Name]),
```
In `terminate/3`, after `ets:delete`:
```erlang
logger:notice("[em_disco] agent disconnected: ~ts", [Name]),
```

---

## 2. EDoc Pass

### Style (same as emquest)
- `%%% @doc` module-level docstring on every module
- `@doc` + `-spec` on every exported function
- `%% @private` + inline comment on key private functions
- Language: English throughout

### Modules to document

| Module | Current state | Work needed |
|--------|--------------|-------------|
| `em_disco_app.erl` | Stub @doc | Add @spec on start/2, stop/1; full module doc |
| `em_disco_sup.erl` | Partial | Complete route table, @doc on init/1 |
| `em_disco.erl` | Good stubs | Add @spec on query/1, query/2, list_agents/0, list_capabilities/0 |
| `em_disco_handlers.erl` | Partial | @doc on all cowboy callbacks, handshake protocol in moduledoc |
| `em_disco_http_handler.erl` | Partial | @doc on init/2, request/response format in moduledoc |
| `em_disco_registry_handler.erl` | Partial | @doc on init/2, response shape in moduledoc |
| `em_disco_mcp_handler.erl` | Partial | @doc on init/2 and helpers, tools table in moduledoc |
| `em_disco_rate.erl` | Good | @spec on check/1; note hot-path design in moduledoc |
| `em_disco_auth.erl` | Good | @spec on issue/2, verify/1 |

New module `em_disco_sse_registry.erl` and `em_disco_registry_events_handler.erl` get full docs at creation time.

---

## 3. SSE Push for `/registry/events`

### Goal
Replace polling with a persistent SSE connection. Browser receives a push notification whenever the agent list changes (connect or disconnect). No polling interval; no stale data.

### New modules

#### `em_disco_sse_registry.erl` — gen_server
Responsibility: track connected browser SSE processes and broadcast to them.

**State:** `#{subscribers => [{Pid, Ref}]}` — monitor refs for automatic cleanup.

**API:**
```erlang
-export([start_link/0, subscribe/0, broadcast/0]).
```

- `subscribe/0` — called by `em_disco_registry_events_handler` on SSE open. Adds calling PID to subscriber set, returns `ok`.
- `broadcast/0` — reads current `agent_registry` ETS, encodes full agent list as JSON, sends `{registry_update, Payload}` to all subscribers.
- `handle_info({'DOWN', Ref, process, Pid, _}, State)` — removes dead subscribers.

#### `em_disco_registry_events_handler.erl` — cowboy_handler
Responsibility: serve `GET /registry/events` as an SSE stream.

```erlang
init(Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>  => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Req0),
    em_disco_sse_registry:subscribe(),
    loop(Req, State).

loop(Req, State) ->
    receive
        {registry_update, Payload} ->
            cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req),
            loop(Req, State)
    after 30000 ->
        %% heartbeat keepalive comment
        cowboy_req:stream_body(<<": ping\n\n">>, nofin, Req),
        loop(Req, State)
    end.
```

### Changes to existing modules

**`em_disco_sup.erl`**
- Add `em_disco_sse_registry` as permanent child before Cowboy start
- Add route: `{"/registry/events", em_disco_registry_events_handler, #{}}`

**`em_disco_handlers.erl`**
- After `ets:insert(agent_registry, ...)` in `agent_hello` branch: `em_disco_sse_registry:broadcast()`
- After `ets:delete(agent_registry, Name)` in `terminate/3`: `em_disco_sse_registry:broadcast()`

### Frontend (`index.html`)

Remove:
```javascript
loadRegistry();
setInterval(loadRegistry, 15000);
```

Replace with:
```javascript
loadRegistry(); // initial load

const evtSource = new EventSource('/registry/events');
evtSource.onmessage = e => {
    try { renderRegistry(JSON.parse(e.data)); }
    catch (_) {}
};
evtSource.onerror = () => {
    // Browser auto-reconnects; optionally fall back to polling
};
```

`renderRegistry(data)` is a refactor of the existing `loadRegistry` body: accept the agent list as a parameter instead of fetching it. `loadRegistry` keeps its fetch path (for initial load).

---

## 4. Dependencies

No changes to `rebar.config`. All existing dependencies remain.

---

## Spec Self-Review

- **Placeholders:** none
- **Contradictions:** none — `subscribe/0` takes no args (PID implicit via `self()`), consistent with loop using `receive`
- **Scope:** three contained, independent tasks; each can be committed separately
- **Ambiguity:** SSE payload is full agent list (not delta) — simplest for browser, robust to missed events
