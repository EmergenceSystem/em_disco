%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco — Discovery and Query Dispatch Core
%%%
%%% Public API of the `em_disco' application.
%%% Manages the service lifecycle and provides `query/1' to fan out
%%% a request to all connected filters/agents and aggregate results.
%%%
%%% === ETS tables (owned by em_disco_sup) ===
%%%
%%%   `filter_registry'  — `{Name :: binary(), Pid :: pid()}'
%%%        All connected nodes (filters and agents alike).
%%%
%%%   `agent_registry'   — `{Name :: binary(), Capabilities :: [binary()], ConnectedAt :: integer()}'
%%%        Agents only. Populated when a node sends an `agent_hello' frame.
%%%
%%%   `pending_queries'  — `{Id :: binary(), Pid :: pid()}'
%%%        In-flight queries waiting for results.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco).

-export([
    start/0,
    stop/0,
    query/1,
    list_filters/0,
    list_agents/0
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
%% @doc Fans out a query to all connected filters/agents and collects results.
%%
%% Every node in `filter_registry' receives the query regardless of
%% whether it has announced agent capabilities or not.
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
%% @doc Returns the names of all currently connected nodes
%%      (both plain filters and agents).
%% @end
%%--------------------------------------------------------------------
-spec list_filters() -> [binary()].
list_filters() ->
    [Name || {Name, _Pid} <- ets:tab2list(filter_registry)].

%%--------------------------------------------------------------------
%% @doc Returns the registry entries for nodes that announced
%%      themselves as agents via `agent_hello'.
%%
%% Each entry is a map with:
%%   `name'          — binary node name
%%   `capabilities'  — list of capability binaries
%%   `connected_at'  — Unix timestamp (seconds) of the hello frame
%% @end
%%--------------------------------------------------------------------
-spec list_agents() -> [map()].
list_agents() ->
    [#{
        name          => Name,
        capabilities  => Caps,
        connected_at  => ConnectedAt
    } || {Name, Caps, ConnectedAt} <- ets:tab2list(agent_registry)].

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
