%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco — Discovery and Query Dispatch Core
%%%
%%% Public API of the `em_disco' application.
%%% Manages the service lifecycle and provides `query/1' to fan out
%%% a request to all connected agents and aggregate results.
%%%
%%% ETS tables (owned by em_disco_sup):
%%%
%%%   `agent_registry'  — {Name :: binary(), Caps :: [binary()],
%%%                         ConnectedAt :: integer(), Pid :: pid()}
%%%        All connected agents. Populated on `agent_hello',
%%%        cleared on WebSocket disconnect.
%%%
%%%   `pending_queries' — {Id :: binary(), Pid :: pid()}
%%%        In-flight queries waiting for results.
%%%        Entries are deleted when all expected results arrive
%%%        OR when the collection timeout fires — whichever comes first.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco).

-export([
    start/0,
    stop/0,
    query/1,
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
%% @doc Fans out a query to all connected agents and collects results.
%%
%% Every agent in `agent_registry' receives the query payload.
%% The pending_queries entry is always cleaned up — either in the
%% success branch (all agents replied) or in the timeout branch.
%% @end
%%--------------------------------------------------------------------
-spec query(binary()) -> list().
query(Body) ->
    Agents = ets:tab2list(agent_registry),
    case Agents of
        [] ->
            io:format("[disco] query received but no agents connected~n"),
            [];
        _ ->
            Id      = generate_query_id(),
            Payload = json:encode(#{
                <<"action">> => <<"query">>,
                <<"id">>     => Id,
                <<"body">>   => Body
            }),
            ets:insert(pending_queries, {Id, self()}),
            lists:foreach(fun({Name, _Caps, _ConnectedAt, Pid}) ->
                io:format("[disco] Dispatching query ~s to agent ~s~n", [Id, Name]),
                Pid ! {send, Payload}
            end, Agents),
            collect_results(length(Agents), Id, ?QUERY_TIMEOUT_MS, [])
    end.

%%--------------------------------------------------------------------
%% @doc Returns the registry entries for all connected agents.
%%
%% Each entry is a map with:
%%   `name'          — binary agent name
%%   `capabilities'  — list of capability binaries
%%   `connected_at'  — Unix timestamp (seconds) of the hello frame
%% @end
%%--------------------------------------------------------------------
-spec list_agents() -> [map()].
list_agents() ->
    [#{
        name         => Name,
        capabilities => Caps,
        connected_at => ConnectedAt
    } || {Name, Caps, ConnectedAt, _Pid} <- ets:tab2list(agent_registry)].

%%====================================================================
%% Internal helpers
%%====================================================================

-spec collect_results(non_neg_integer(), binary(), non_neg_integer(), list()) -> list().
collect_results(0, Id, _Timeout, Acc) ->
    %% All expected agents replied — clean up and return.
    io:format("[disco] All results collected for query ~s~n", [Id]),
    ets:delete(pending_queries, Id),
    Acc;
collect_results(N, Id, Timeout, Acc) ->
    receive
        {query_result, Id, Result} ->
            io:format("[disco] Got result ~p/~p for query ~s~n",
                      [length(Acc) + 1, length(Acc) + N, Id]),
            collect_results(N - 1, Id, Timeout, [Result | Acc])
    after Timeout ->
        %% Some agents did not respond in time — clean up and return
        %% whatever was collected so far.
        io:format("[disco] Timeout: ~p agent(s) did not respond for query ~s~n",
                  [N, Id]),
        ets:delete(pending_queries, Id),
        Acc
    end.

-spec generate_query_id() -> binary().
generate_query_id() ->
    base64:encode(crypto:strong_rand_bytes(8)).
