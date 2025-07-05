-module(em_disco).
-export([
    start/0,
    stop/0,
    register_filter/1,
    unregister_filter/1,
    query/1,
    add_discovery_source/1,
    remove_discovery_source/1,
    discover_filters/0
]).

%%% API Functions

start() ->
    io:format("[INFO] Starting em_disco application...~n"),
    application:ensure_all_started(em_disco),
    embryo:start_discovery(),
    io:format("[SUCCESS] em_disco application started with automatic filter discovery.~n"),
    ok.

stop() ->
    io:format("[INFO] Stopping em_disco application...~n"),
    embryo:stop_discovery(),
    application:stop(em_disco),
    io:format("[SUCCESS] em_disco application stopped.~n"),
    ok.

register_filter(Url) when is_binary(Url) ->
    embryo:add_filter(Url).

unregister_filter(Url) when is_binary(Url) ->
    embryo:remove_filter(Url).

add_discovery_source(Source) when is_binary(Source) ->
    embryo:add_discovery_source(Source).

remove_discovery_source(Source) when is_binary(Source) ->
    embryo:remove_discovery_source(Source).

query(Body) ->
    embryo:aggregate(Body).

discover_filters() ->
    embryo:discover_filters().
