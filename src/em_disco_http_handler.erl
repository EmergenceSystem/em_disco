%%%-------------------------------------------------------------------
%%% @doc
%%% HTTP Handler for Emquest Client Queries
%%%
%%% Handles `POST /query' requests from the Emquest client.
%%% This is the only HTTP surface in `em_disco'; all filter
%%% communication goes through WebSocket (see `em_disco_handlers').
%%%
%%% === Request format (JSON body) ===
%%% ```
%%%   { "value": "<query>" }
%%%   or
%%%   { "query": "<query>" }
%%% '''
%%%
%%% === Response format (JSON body) ===
%%% ```
%%%   { "embryo_list": [ <result>, ... ] }
%%% '''
%%%
%%% Results are grouped by their `"type"' field and ordered by
%%% descending frequency: the most represented type comes first,
%%% then the next, and so on. Items without a `"type"' field are
%%% grouped under the internal key `<<>>` and placed last.
%%%
%%% Returns HTTP 400 on bad input, HTTP 500 on internal errors.
%%%
%%% This module is intentionally thin: it parses the request and
%%% delegates all logic to `em_disco:query/1'. Swapping the transport
%%% layer only requires changing this file.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_http_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Cowboy request entry point.
%%
%% Reads the request body, extracts the query string, forwards it to
%% `em_disco:query/1', and returns the aggregated filter results as
%% a JSON response.
%% @end
%%--------------------------------------------------------------------
init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    Req2 = case parse_query_body(Body) of
        {ok, QueryBin} ->
            Results = em_disco:query(QueryBin),
            %% Each agent returns either a list of items or a single item.
            %% Use flatmap instead of lists:flatten — flatten is recursive
            %% and would destroy nested lists inside items (e.g. ips fields).
            Embryos = lists:flatmap(fun
                (L) when is_list(L) -> L;
                (M) when is_map(M)  -> [M];
                (_)                  -> []
            end, Results),
            io:format("[disco] Flat embryos (~p items)~n", [length(Embryos)]),
            Sorted       = sort_by_type_frequency(Embryos),
            ResponseBody = json:encode(#{<<"embryo_list">> => Sorted}),
            cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                ResponseBody,
                Req1);

        {error, Reason} ->
            io:format("[disco] HTTP query parse error: ~p~n", [Reason]),
            cowboy_req:reply(400,
                #{<<"content-type">> => <<"application/json">>},
                json:encode(#{<<"error">> => <<"invalid_request">>}),
                Req1)
    end,

    {ok, Req2, State}.

%%====================================================================
%% Internal helpers
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Parses a raw JSON body and extracts the query binary.
%%
%% Accepts both `"value"' and `"query"' as key names for compatibility
%% with different Emquest client versions.
%%
%% @return `{ok, QueryBin}' on success.
%%         `{error, empty_query}' when the key is present but blank.
%%         `{error, invalid_json}' when the body cannot be decoded.
%% @end
%%--------------------------------------------------------------------
-spec parse_query_body(binary()) -> {ok, binary()} | {error, atom()}.
parse_query_body(Body) when is_binary(Body) ->
    try
        Map = json:decode(Body),
        QueryBin = case maps:get(<<"value">>, Map, undefined) of
            undefined -> maps:get(<<"query">>, Map, <<>>);
            V         -> V
        end,
        case QueryBin of
            <<>> -> {error, empty_query};
            _    -> {ok, QueryBin}
        end
    catch
        _:_ -> {error, invalid_json}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Reorders a flat list of result maps by descending type frequency.
%%
%% Each item is expected to be a map that may contain a `<<"type">>'
%% key. Items sharing the same type are kept contiguous. Groups are
%% ordered from the most frequent type to the least frequent.
%% Items without a `<<"type">' key are treated as type `<<>>' and
%% placed at the end.
%%
%% Example
%% ```
%%   Input : [dns_a, url, dns_a, url, dns_a, txt]
%%   Output: [dns_a, dns_a, dns_a, url, url, txt]
%% '''
%%
%% @param Items   Flat list of decoded JSON maps.
%% @return        Same items, reordered by type frequency.
%% @end
%%--------------------------------------------------------------------
-spec sort_by_type_frequency([map()]) -> [map()].
sort_by_type_frequency([]) ->
    [];
sort_by_type_frequency(Items) ->
    %% 1. Group items by type, preserving insertion order within each group.
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

    %% 2. Sort types by descending bucket size (most frequent first).
    SortedTypes = lists:sort(
        fun(A, B) ->
            length(maps:get(A, GroupMap)) >= length(maps:get(B, GroupMap))
        end,
        TypeOrder
    ),

    io:format("[disco] Result type order (by frequency): ~p~n",
              [[{T, length(maps:get(T, GroupMap))} || T <- SortedTypes]]),

    %% 3. Concatenate buckets in sorted type order.
    lists:flatmap(fun(Type) -> maps:get(Type, GroupMap) end, SortedTypes).
