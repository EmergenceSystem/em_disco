%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco Top-Level Supervisor
%%%
%%% Starts the Cowboy HTTP/WebSocket server and initialises the two
%%% ETS tables used for runtime state:
%%%
%%% <ul>
%%%   <li>`filter_registry' — maps filter name (binary) to WS handler
%%%       pid.</li>
%%%   <li>`pending_queries' — maps query id (binary) to caller
%%%       pid.</li>
%%% </ul>
%%%
%%% Two routes are registered on port 8080:
%%% <ul>
%%%   <li>`GET  /ws'    → `em_disco_handlers'     (WebSocket, persistent)</li>
%%%   <li>`POST /query' → `em_disco_http_handler' (HTTP, short-lived)</li>
%%% </ul>
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
    %% ETS tables are owned by this supervisor process so they survive
    %% individual child crashes.
    ets:new(filter_registry, [set, named_table, public, {read_concurrency, true}]),
    ets:new(pending_queries,  [set, named_table, public]),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws",    em_disco_handlers,     []},
            {"/query", em_disco_http_handler, []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(disco_listener,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ),

    io:format("[em_disco] Started on port 8080~n"),
    io:format("[em_disco]   WS  filters : ws://localhost:8080/ws~n"),
    io:format("[em_disco]   HTTP queries: http://localhost:8080/query~n"),

    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
