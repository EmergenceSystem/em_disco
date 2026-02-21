%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco — Discovery and Query Dispatch Core
%%%
%%% This module is the public API of the `em_disco' application.
%%% It manages the service lifecycle and provides the `query/1'
%%% function that fans out a request to all connected filters and
%%% aggregates their responses.
%%%
%%% === Architecture overview ===
%%%
%%% ```
%%%  Emquest client
%%%       │  POST /query  (HTTP)
%%%       ▼
%%%  em_disco_http_handler
%%%       │  em_disco:query/1
%%%       ▼
%%%  em_disco ──── fan-out {send, Payload} ────▶ em_disco_handlers (N×)
%%%       │                                              │ WS frame
%%%       │                                              ▼
%%%       │                                         em_filter (N×)
%%%       │                                              │ WS frame
%%%       ◀──────── {query_result, Id, Data} ───────────┘
%%%       │  collect_results/4
%%%       ▼
%%%  [result, ...]  returned to HTTP caller
%%% '''
%%%
%%% === ETS tables (owned by em_disco_sup) ===
%%%
%%%   `filter_registry'  — `{Name :: binary(), Pid :: pid()}'
%%%   `pending_queries'  — `{Id :: binary(),   Pid :: pid()}'
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco).

-export([
    start/0,
    stop/0,
    query/1,
    list_filters/0
]).

-define(QUERY_TIMEOUT_MS, 5000).

%%--------------------------------------------------------------------
%% @doc Starts the em_disco application and all its dependencies.
%% @end
%%--------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(em_disco),
    io:format("[disco] em_disco started~n").

%%--------------------------------------------------------------------
%% @doc Stops the Cowboy listener and the em_disco application.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok.
stop() ->
    cowboy:stop_listener(disco_listener),
    application:stop(em_disco),
    io:format("[disco] em_disco stopped~n").

%%--------------------------------------------------------------------
%% @doc Fans out a query to all connected filters and collects results.
%% @end
%%--------------------------------------------------------------------
-spec query(binary()) -> list().
query(Body) ->
    Filters = ets:tab2list(filter_registry),
    case Filters of
        [] ->
            io:format("[disco] query received but no filters connected~n"),
            [];
        _ ->
            Id      = generate_query_id(),
            Payload = json:encode(#{
                <<"action">> => <<"query">>,
                <<"id">>     => Id,
                <<"body">>   => Body
            }),
            ets:insert(pending_queries, {Id, self()}),
            lists:foreach(fun({Name, Pid}) ->
                io:format("[disco] Dispatching query ~s to filter ~s~n", [Id, Name]),
                Pid ! {send, Payload}
            end, Filters),
            collect_results(length(Filters), Id, ?QUERY_TIMEOUT_MS, [])
    end.

%%--------------------------------------------------------------------
%% @doc Returns the names of all currently connected filters.
%% @end
%%--------------------------------------------------------------------
-spec list_filters() -> [binary()].
list_filters() ->
    [Name || {Name, _Pid} <- ets:tab2list(filter_registry)].

%%====================================================================
%% Internal helpers
%%====================================================================

-spec collect_results(non_neg_integer(), binary(), non_neg_integer(), list()) -> list().
collect_results(0, Id, _Timeout, Acc) ->
    io:format("[disco] All results collected for query ~s~n", [Id]),
    Acc;
collect_results(N, Id, Timeout, Acc) ->
    receive
        {query_result, Id, Result} ->
            io:format("[disco] Got result ~p/~p for query ~s~n",
                      [length(Acc) + 1, length(Acc) + N, Id]),
            collect_results(N - 1, Id, Timeout, [Result | Acc])
    after Timeout ->
        io:format("[disco] Timeout: ~p filter(s) did not respond for query ~s~n",
                  [N, Id]),
        ets:delete(pending_queries, Id),
        Acc
    end.

-spec generate_query_id() -> binary().
generate_query_id() ->
    base64:encode(crypto:strong_rand_bytes(8)).
