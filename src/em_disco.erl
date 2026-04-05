%%%-------------------------------------------------------------------
%%% @doc em_disco core API — query dispatch and agent registry inspection.
%%%
%%% Provides two groups of functions:
%%%
%%% === Query dispatch ===
%%%
%%% {@link query/1} and {@link query/2} fan out a query to all connected
%%% agents, collect results within a configurable deadline, and return
%%% the aggregated list. Agents respond asynchronously; the calling
%%% process blocks until all agents reply or the deadline expires.
%%%
%%% ETS tables used:
%%% <ul>
%%%   <li>`agent_registry'  — `{Name, Caps, ConnectedAt, Pid}' tuples,
%%%       maintained by {@link em_disco_handlers}</li>
%%%   <li>`pending_queries' — `{QueryId, CallerPid}' entries for
%%%       in-flight queries, owned by this module</li>
%%% </ul>
%%%
%%% === Registry inspection ===
%%%
%%% {@link list_agents/0} and {@link list_capabilities/0} read
%%% `agent_registry' directly — safe to call from any process.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco).

-export([
    start/0,
    stop/0,
    query/1,
    query/2,
    list_agents/0,
    list_capabilities/0
]).

-define(QUERY_TIMEOUT_MS, application:get_env(em_disco, query_timeout_ms, 5000)).

%%--------------------------------------------------------------------
%% @doc Convenience: ensures all dependencies are started then starts
%% the `em_disco' application.
%%
%% Intended for use in the Erlang shell. In a release, the application
%% is started automatically via `em_disco_app'.
%% @end
%%--------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(em_disco),
    logger:info("em_disco started").

%%--------------------------------------------------------------------
%% @doc Convenience: stops the Cowboy listener and the `em_disco'
%% application.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok.
stop() ->
    cowboy:stop_listener(disco_listener),
    application:stop(em_disco),
    logger:info("em_disco stopped").

%%--------------------------------------------------------------------
%% @doc Broadcasts a query to all connected agents.
%% @end
%%--------------------------------------------------------------------
-spec query(binary()) -> list().
query(Body) ->
    query(Body, []).

%%--------------------------------------------------------------------
%% @doc Fans out a query to agents matching the given capabilities.
%%
%% Capabilities = []  → broadcast (all agents receive the query)
%% Capabilities = […] → only matching agents receive it
%%
%% If capabilities are specified but no agent matches, falls back to
%% broadcast so the query is never silently dropped.
%% @end
%%--------------------------------------------------------------------
-spec query(binary(), [binary()]) -> list().
query(Body, Capabilities) ->
    AllAgents = ets:tab2list(agent_registry),
    case AllAgents of
        [] -> [];
        _ ->
            Agents  = select_agents(AllAgents, Capabilities),
            Id      = generate_query_id(),
            Payload = json:encode(#{
                <<"action">> => <<"query">>,
                <<"id">>     => Id,
                <<"body">>   => Body
            }),
            ets:insert(pending_queries, {Id, self()}),
            lists:foreach(fun({Name, _Caps, _At, Pid}) ->
                logger:debug("Dispatching query", #{query_id => Id, agent => Name}),
                Pid ! {send, Payload}
            end, Agents),
            %% Deadline = now + total timeout (not per-agent)
            Deadline = erlang:monotonic_time(millisecond) + ?QUERY_TIMEOUT_MS,
            collect_results(length(Agents), Id, Deadline, [])
    end.

%% @private
%% @doc Collect query results from N agents until all respond or the deadline passes.
%%
%% `Deadline' is an absolute `erlang:monotonic_time(millisecond)' value
%% shared across all agents — a single global deadline, not per-agent.
%% Results that arrive before the deadline are accumulated in `Acc'.
%% If the deadline fires with agents still pending, a warning is logged
%% and the partial result is returned.
%% @end
-spec collect_results(non_neg_integer(), binary(), integer(), list()) -> list().
collect_results(0, Id, _Deadline, Acc) ->
    ets:delete(pending_queries, Id),
    Acc;
collect_results(N, Id, Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {query_result, Id, Result} ->
            collect_results(N - 1, Id, Deadline, [Result | Acc])
    after Remaining ->
        logger:warning("Query timeout", #{pending => N, query_id => Id}),
        ets:delete(pending_queries, Id),
        Acc
    end.

%%--------------------------------------------------------------------
%% @doc Returns the registry entries for all connected agents.
%% @end
%%--------------------------------------------------------------------
-spec list_agents() -> [map()].
list_agents() ->
    [#{name         => Name,
       capabilities => Caps,
       connected_at => ConnectedAt}
     || {Name, Caps, ConnectedAt, _Pid} <- ets:tab2list(agent_registry)].

%%--------------------------------------------------------------------
%% @doc Returns the deduplicated list of all capabilities currently
%% offered by connected agents.
%% @end
%%--------------------------------------------------------------------
-spec list_capabilities() -> [binary()].
list_capabilities() ->
    lists:usort(lists:flatmap(
        fun({_, Caps, _, _}) -> Caps end,
        ets:tab2list(agent_registry)
    )).

%%====================================================================
%% Internal helpers
%%====================================================================

%% @private
%% @doc Filter agents by capability set.
%%
%% Returns all agents whose capability list overlaps with `Caps'.
%% An empty `Caps' list returns all agents (broadcast).
%% If `Caps' is non-empty but no agent matches, falls back to broadcast
%% so the query is never silently dropped.
%% @end
-spec select_agents(list(), [binary()]) -> list().
select_agents(All, []) ->
    All;
select_agents(All, Caps) ->
    Matching = [A || {_, AgentCaps, _, _} = A <- All,
                     lists:any(fun(C) -> lists:member(C, AgentCaps) end, Caps)],
    case Matching of
        [] ->
            logger:info("No agent matches, broadcasting", #{capabilities => Caps}),
            All;
        _ ->
            Matching
    end.

%% @private
%% @doc Generate a random 8-byte base64 query ID.
%%
%% Used to correlate agent responses with the originating query.
%% Collision probability is negligible at typical query rates.
%% @end
-spec generate_query_id() -> binary().
generate_query_id() ->
    base64:encode(crypto:strong_rand_bytes(8)).
