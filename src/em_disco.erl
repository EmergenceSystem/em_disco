%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco — Discovery and Query Dispatch Core
%%%
%%% query/1 — broadcast to all agents (backwards compatible)
%%% query/2 — route to agents matching the given capabilities list.
%%%            Empty list = broadcast to all.
%%%
%%% @author Steve Roques
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

-spec start() -> ok.
start() ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(em_disco),
    logger:info("em_disco started").

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

-spec generate_query_id() -> binary().
generate_query_id() ->
    base64:encode(crypto:strong_rand_bytes(8)).
