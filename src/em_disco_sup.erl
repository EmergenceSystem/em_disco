%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco Top-Level Supervisor
%%%
%%% === HTTP routes (port 8080) ===
%%%
%%%   GET  /           → index.html landing page (registry UI)
%%%   GET  /ws         → em_disco_handlers        (WebSocket, agents)
%%%   POST /query      → em_disco_http_handler    (HTTP queries)
%%%   GET  /registry   → em_disco_registry_handler (agent list JSON)
%%%   GET  /mcp        → em_disco_mcp_handler     (MCP SSE channel)
%%%   POST /mcp        → em_disco_mcp_handler     (MCP JSON-RPC)
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(agent_registry,  [set, named_table, public, {read_concurrency, true}]),
    ets:new(pending_queries, [set, named_table, public]),

    Dispatch = cowboy_router:compile([
        {'_', [
            %% Landing page — live registry UI.
            {"/",         cowboy_static,
                          {priv_file, em_disco, "templates/index.html"}},

            %% Persistent WebSocket endpoint — agents connect here.
            {"/ws",       em_disco_handlers,         []},

            %% HTTP endpoint — Emquest and other clients post queries here.
            {"/query",    em_disco_http_handler,     []},

            %% HTTP endpoint — read live agent list and their capabilities.
            {"/registry", em_disco_registry_handler, []},

            %% MCP endpoint — JSON-RPC over HTTP or SSE.
            %% GET  /mcp → SSE channel (server notifications)
            %% POST /mcp → JSON-RPC request/response
            {"/mcp",      em_disco_mcp_handler,      []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(disco_listener,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ),

    io:format("[em_disco] Started on port 8080~n"),
    io:format("[em_disco]   HTTP  landing  : http://localhost:8080~n"),
    io:format("[em_disco]   WS    agents   : ws://localhost:8080/ws~n"),
    io:format("[em_disco]   HTTP  queries  : http://localhost:8080/query~n"),
    io:format("[em_disco]   HTTP  registry : http://localhost:8080/registry~n"),
    io:format("[em_disco]   MCP   server   : http://localhost:8080/mcp~n"),

    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
