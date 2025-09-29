-module(em_disco_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    % Create ETS table for filter registry
    ets:new(filter_registry, [set, named_table, public, {read_concurrency, true}]),
    
    % Ensure inets is started
    application:ensure_all_started(inets),
    
    % Start Wade server
    {ok, _Pid} = wade:start_link(8080),
    
    % Register routes
    wade:route(post, "/register", fun em_disco_handlers:handle_register/1, []),
    wade:route(post, "/unregister", fun em_disco_handlers:handle_unregister/1, []),
    wade:route(post, "/query", fun em_disco_handlers:handle_query/1, []),
    
    io:format("em_disco service started on port 8080~n"),
    
    % Supervisor specification (no children, Wade manages itself)
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    
    {ok, {SupFlags, []}}.

