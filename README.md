# em_disco
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

An Erlang/OTP discovery service for Emergence filters and agents.

![Screenshot](https://github.com/EmergenceSystem/em_disco/blob/main/em_disco.png)

## Overview

`em_disco` is the central hub of the Emergence system. Filters and agents connect to it over a persistent WebSocket and receive broadcasted queries. HTTP clients post queries and receive aggregated results.

In addition to query dispatch, `em_disco` acts as a **live registry** for agents — nodes that announce their capabilities on connection are discoverable via `GET /registry`.

## Build

```bash
rebar3 compile
rebar3 shell
```

## HTTP endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/query` | Submit a query, receive aggregated results |
| `GET` | `/ws` | WebSocket endpoint for filters and agents |
| `GET` | `/registry` | List connected agents and their capabilities |

### POST /query

```bash
curl -X POST http://localhost:8080/query \
     -H "content-type: application/json" \
     -d '{"value": "your search term"}'
```

```json
{"embryo_list": [...]}
```

### GET /registry

```bash
curl http://localhost:8080/registry
```

```json
{
  "agents": [
    {
      "name": "synth_agent",
      "capabilities": ["summarize", "llm"],
      "connected_at": 1714000000
    }
  ]
}
```

Returns an empty `agents` list when no agents are connected. Plain filters (nodes that never sent `agent_hello`) do not appear here.

## WebSocket protocol

All nodes connect to `ws://localhost:8080/ws`.

### Filter / Agent → Disco

```json
// mandatory first frame — all nodes
{"action": "register", "name": "my_filter"}

// optional — agents only, sent after register
{"action": "agent_hello", "capabilities": ["summarize", "llm"]}

// query response
{"action": "result", "id": "<query_id>", "data": <result>}
```

### Disco → Filter / Agent

```json
// acknowledgement
{"status": "ok", "action": "registered"}
{"status": "ok", "action": "agent_registered", "capabilities": [...]}

// broadcasted query
{"action": "query", "id": "<query_id>", "body": "search term"}
```

## Configuration

Default port is `8080`. To change it, edit `em_disco_sup.erl` or set the port in your release config.

## Related

- [em_filter](https://github.com/EmergenceSystem/em_filter) — library for building filters and agents
- [Emquest](https://github.com/EmergenceSystem/Emquest) — web client
- [em_discord_bot](https://github.com/EmergenceSystem/em_discord_bot) — Discord client

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
