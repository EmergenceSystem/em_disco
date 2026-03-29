%%%-------------------------------------------------------------------
%%% @doc
%%% HTTP Handler for Emquest Client Queries
%%%
%%% POST /query
%%%
%%% === Request format ===
%%%
%%%   { "value": "<query>" }
%%%   { "query": "<query>" }
%%%   { "query": "<query>", "capabilities": ["dns", "rss"] }
%%%
%%% When "capabilities" is present and non-empty, only agents that
%%% advertised at least one of those capabilities receive the query.
%%% Omit "capabilities" (or pass []) for broadcast to all agents.
%%%
%%% === Response format ===
%%%
%%%   { "embryo_list": [ <result>, ... ] }
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_http_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    {IP, _Port} = cowboy_req:peer(Req0),
    case em_disco_rate:check(IP) of
        {error, rate_limited} ->
            Req = cowboy_req:reply(429,
                #{<<"content-type">> => <<"application/json">>,
                  <<"retry-after">> => <<"1">>},
                json:encode(#{<<"error">> => <<"rate_limited">>}), Req0),
            {ok, Req, State};
        ok ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Req2 = case parse_query_body(Body) of
                {ok, QueryBin, Caps} ->
                    Results = em_disco:query(QueryBin, Caps),
                    Embryos = lists:flatmap(fun
                        (L) when is_list(L) -> L;
                        (M) when is_map(M)  -> [M];
                        (_)                  -> []
                    end, Results),
                    logger:debug("Query results", #{count => length(Embryos)}),
                    Sorted       = sort_by_type_frequency(Embryos),
                    ResponseBody = json:encode(#{<<"embryo_list">> => Sorted}),
                    cowboy_req:reply(200,
                        #{<<"content-type">> => <<"application/json">>,
                          <<"access-control-allow-origin">> => <<"*">>},
                        ResponseBody, Req1);
                {error, Reason} ->
                    logger:warning("HTTP query parse error", #{reason => Reason}),
                    cowboy_req:reply(400,
                        #{<<"content-type">> => <<"application/json">>},
                        json:encode(#{<<"error">> => <<"invalid_request">>}), Req1)
            end,
            {ok, Req2, State}
    end.

%%====================================================================
%% Internal helpers
%%====================================================================

-spec parse_query_body(binary()) ->
    {ok, binary(), [binary()]} | {error, atom()}.
parse_query_body(Body) when is_binary(Body) ->
    try
        Map      = json:decode(Body),
        QueryBin = case maps:get(<<"value">>, Map, undefined) of
            undefined -> maps:get(<<"query">>, Map, <<>>);
            V         -> V
        end,
        Caps = case maps:get(<<"capabilities">>, Map, []) of
            L when is_list(L) -> [C || C <- L, is_binary(C)];
            _                 -> []
        end,
        case QueryBin of
            <<>> -> {error, empty_query};
            _    -> {ok, QueryBin, Caps}
        end
    catch
        _:_ -> {error, invalid_json}
    end.

-spec sort_by_type_frequency([map()]) -> [map()].
sort_by_type_frequency([]) -> [];
sort_by_type_frequency(Items) ->
    {GroupMap, TypeOrder} = lists:foldl(
        fun(Item, {Map, Order}) ->
            Type = case Item of
                #{<<"type">> := T} -> T;
                _                  -> <<>>
            end,
            Bucket   = maps:get(Type, Map, []),
            NewMap   = maps:put(Type, Bucket ++ [Item], Map),
            NewOrder = case lists:member(Type, Order) of
                true  -> Order;
                false -> Order ++ [Type]
            end,
            {NewMap, NewOrder}
        end,
        {#{}, []},
        Items
    ),
    SortedTypes = lists:sort(
        fun(A, B) ->
            length(maps:get(A, GroupMap)) >= length(maps:get(B, GroupMap))
        end,
        TypeOrder
    ),
    io:format("[disco] Result type order: ~p~n",
              [[{T, length(maps:get(T, GroupMap))} || T <- SortedTypes]]),
    lists:flatmap(fun(Type) -> maps:get(Type, GroupMap) end, SortedTypes).
