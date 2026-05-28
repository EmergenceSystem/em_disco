# em_disco
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

em_disco is the bootstrap gossip node of the [Emergence](https://github.com/EmergenceSystem)
distributed discovery network.

---

## Role

em_disco is the first node a new filter or emquest instance contacts to enter the
em-pop gossip ring. It holds a large peer table (up to 10 000 entries) and maintains
continuous gossip with all known nodes. Any new peer that seeds from em_disco is
immediately reachable by the rest of the network.

em_disco does not store queries, results, or agent metadata. It routes gossip — nothing
else.

---

## Architecture

```
em_disco :9100 (gossip)   :9101 (HTTP)
  ├── em_pop gossip node   — maintains peer table via UDP gossip
  └── POST /agent/query    — direct query endpoint (em_filter contract)
```

Filters and emquest instances seed from em_disco once at startup, then maintain their
own peer tables independently. em_disco remains available as a long-lived, well-connected
seed node.

---

## Features

- **em-pop gossip** — maintains a continuously-updated peer table via UDP gossip
- **Bootstrap seed** — any em-pop node that contacts em_disco joins the network
- **Direct query** — `POST /agent/query` accepts queries in the em_filter format
- **Large peer table** — up to 10 000 peers, suitable for a public bootstrap node

---

## Requirements

- Erlang/OTP 27+
- [rebar3](https://rebar3.org)
- [em_filter](https://hex.pm/packages/em_filter) >= 1.4.0

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

Default ports (set via `sys.config` or application env):

| Key | Default | Description |
|-----|---------|-------------|
| `gossip_port` | `9100` | em-pop UDP gossip listen port |
| `query_port` | `9101` | Direct HTTP query listen port |
| `pop_seeds` | `[]` | `[{Host, Port}]` bootstrap peers to seed from |

Example `sys.config`:

```erlang
[{em_disco, [
    {gossip_port, 9100},
    {query_port,  9101},
    {pop_seeds,   [{"em-disco.roques.me", 9100}]}
]}].
```

---

## HTTP API

### POST /agent/query

Standard em_filter query endpoint. Accepts a JSON body with a `"query"` field and
returns a JSON `"results"` list.

```bash
curl -X POST http://localhost:9101/agent/query \
     -H "content-type: application/json" \
     -d '{"query": "erlang"}'
```

---

## Client configuration

To seed your local em-pop node from this em_disco instance, add it to your
`emergence.conf`:

```ini
[em_disco]
pop_port = 9100
```

The `[emquest]` and filter nodes read this to bootstrap their gossip rings.

---

## Project Structure

```
src/
  em_disco_app.erl            — OTP application: starts em_pop gossip + Cowboy listener
  em_disco_sup.erl            — minimal supervisor
  em_disco_query_handler.erl  — POST /agent/query Cowboy handler
```

---

## Related

- [em_filter](https://github.com/EmergenceSystem/em_filter) — library for building em-pop filters
- [Emquest](https://github.com/EmergenceSystem/Emquest) — web gateway with network view
- [em_filter_example](https://github.com/EmergenceSystem/EmergenceSystem/tree/main/filters/em_filter_example) — reference filter

---

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
