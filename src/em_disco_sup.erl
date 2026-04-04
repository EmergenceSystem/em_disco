%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco Top-Level Supervisor
%%%
%%% === HTTP routes (port 8080) ===
%%%
%%%   GET  /           → index.html landing page (registry UI)
%%%   GET  /ws         → em_disco_handlers        (WebSocket, agents)
%%%   POST /query      → em_disco_http_handler    (HTTP queries)
%%%   GET  /registry        → em_disco_registry_handler (agent list JSON)
%%%   GET  /registry/events → em_disco_registry_events_handler (SSE push)
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
    ets:new(rate_buckets,    [set, named_table, public]),

    Port = get_port(),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/",         cowboy_static,
                          {priv_file, em_disco, "templates/index.html"}},
            {"/ws",       em_disco_handlers,         []},
            {"/query",    em_disco_http_handler,     []},
            {"/registry",        em_disco_registry_handler,        []},
            {"/registry/events", em_disco_registry_events_handler, []},
            {"/mcp",             em_disco_mcp_handler,             []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(disco_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    ActualPort = ranch:get_port(disco_listener),
    logger:info("em_disco started", #{port => ActualPort}),

    Children = [
        #{id => em_disco_sse_registry,
          start => {em_disco_sse_registry, start_link, []},
          restart => permanent,
          type => worker},
        #{id => em_disco_rate,
          start => {em_disco_rate, start_link, []},
          restart => permanent,
          type => worker}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.

get_port() ->
    case os:getenv("EM_DISCO_PORT") of
        false -> application:get_env(em_disco, port, 8080);
        Val   -> list_to_integer(Val)
    end.
