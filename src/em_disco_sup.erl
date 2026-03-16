%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco Top-Level Supervisor
%%%
%%% Starts the Cowboy HTTP/WebSocket server and initialises the ETS
%%% tables used for runtime state.
%%%
%%% === ETS tables ===
%%%
%%%   `agent_registry'  — {Name :: binary(), Caps :: [binary()],
%%%                        ConnectedAt :: integer(), Pid :: pid()}
%%%        All connected agents. Populated on agent_hello,
%%%        cleared on WebSocket disconnect.
%%%
%%%   `pending_queries' — {Id :: binary(), Pid :: pid()}
%%%        In-flight queries. Entries are removed when the last result
%%%        arrives or when the collection timeout fires.
%%%
%%% === HTTP routes (port 8080) ===
%%%
%%%   GET  /           → index.html landing page (node registry UI)
%%%   GET  /ws         → em_disco_handlers        (WebSocket, persistent)
%%%   POST /query      → em_disco_http_handler    (HTTP, short-lived)
%%%   GET  /registry   → em_disco_registry_handler (HTTP, read-only)
%%%
%%% Both ETS tables are owned by this supervisor so that they survive
%%% individual child crashes.
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

%% @private
init([]) ->
    %% ETS tables owned by the supervisor so they persist across worker restarts.
    ets:new(agent_registry,  [set, named_table, public, {read_concurrency, true}]),
    ets:new(pending_queries, [set, named_table, public]),

    Dispatch = cowboy_router:compile([
        {'_', [
            %% Landing page — live registry UI.
            {"/",         cowboy_static, {priv_file, em_disco, "templates/index.html"}},
            {"/favicon.ico",  cowboy_static,   {priv_file, em_disco, "static/favicon.ico"}},
            %% Persistent WebSocket endpoint — agents connect here.
            {"/ws",       em_disco_handlers,         []},

            %% HTTP endpoint — Emquest and other clients post queries here.
            {"/query",    em_disco_http_handler,     []},

            %% HTTP endpoint — read live agent list and their capabilities.
            {"/registry", em_disco_registry_handler, []}
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

    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
