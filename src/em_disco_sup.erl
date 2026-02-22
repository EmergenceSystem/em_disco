%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco Top-Level Supervisor
%%%
%%% Starts the Cowboy HTTP/WebSocket server and initialises the ETS
%%% tables used for runtime state.
%%%
%%% === ETS tables ===
%%%
%%%   `filter_registry'  — `{Name :: binary(), Pid :: pid()}'
%%%        Every connected node (filter or agent). Populated on
%%%        `register', cleared on WebSocket disconnect.
%%%
%%%   `agent_registry'   — `{Name :: binary(), Capabilities :: [binary()],
%%%                           ConnectedAt :: integer()}'
%%%        Agents only. Populated on `agent_hello', cleared on
%%%        disconnect. Plain filters never appear here.
%%%
%%%   `pending_queries'  — `{Id :: binary(), Pid :: pid()}'
%%%        In-flight queries. Entries are removed when the last result
%%%        arrives or when the collection timeout fires.
%%%
%%% === HTTP routes (port 8080) ===
%%%
%%%   `GET  /ws'       → `em_disco_handlers'          (WebSocket, persistent)
%%%   `POST /query'    → `em_disco_http_handler'       (HTTP, short-lived)
%%%   `GET  /registry' → `em_disco_registry_handler'   (HTTP, read-only)
%%%
%%% All ETS tables are owned by this supervisor process so that they
%%% survive individual child crashes.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%%--------------------------------------------------------------------
%% @doc Starts the top-level supervisor and registers it locally.
%%
%% @return `{ok, Pid}' on success, `{error, Reason}' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @private
init([]) ->
    %% ── ETS tables ──────────────────────────────────────────────────
    %%
    %% Owned by the supervisor so they persist across worker restarts.

    %% All connected nodes (filters and agents).
    ets:new(filter_registry, [set, named_table, public, {read_concurrency, true}]),

    %% Agents only — nodes that sent an `agent_hello' frame.
    %% The Queen reads this table via GET /registry to discover
    %% available capabilities before orchestrating a swarm query.
    ets:new(agent_registry,  [set, named_table, public, {read_concurrency, true}]),

    %% In-flight queries awaiting results from connected nodes.
    ets:new(pending_queries,  [set, named_table, public]),

    %% ── HTTP / WebSocket routes ──────────────────────────────────────
    Dispatch = cowboy_router:compile([
        {'_', [
            %% Persistent WebSocket endpoint — filters and agents connect here.
            {"/ws",       em_disco_handlers,          []},

            %% HTTP endpoint — Emquest and other clients post queries here.
            {"/query",    em_disco_http_handler,      []},

            %% HTTP endpoint — Queen agents GET this to discover live agents
            %% and their capabilities before orchestrating a swarm query.
            {"/registry", em_disco_registry_handler,  []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(disco_listener,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ),

    io:format("[em_disco] Started on port 8080~n"),
    io:format("[em_disco]   WS    nodes    : ws://localhost:8080/ws~n"),
    io:format("[em_disco]   HTTP  queries  : http://localhost:8080/query~n"),
    io:format("[em_disco]   HTTP  registry : http://localhost:8080/registry~n"),

    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
