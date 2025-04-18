-module(em_disco_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    % Start the ETS table for filter registry
    ets:new(filter_registry, [set, named_table, public, {read_concurrency, true}]),
    
    % Ensure inets is started
    {ok, _} = application:ensure_all_started(inets),
    
    % Define the Cowboy routes
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/register", register_handler, []},
            {"/unregister", unregister_handler, []},
            {"/query", aggregate_handler, []}
        ]}
    ]),
    
    % Start Cowboy
    {ok, _} = cowboy:start_clear(em_disco_http_listener, 
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ),
    
    io:format("em_disco service started on port 8080~n"),
    
    % Supervisor specification
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    
    % Child specifications (none for now as Cowboy manages its own processes)
    {ok, {SupFlags, []}}.
