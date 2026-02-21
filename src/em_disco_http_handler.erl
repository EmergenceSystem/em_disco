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
            Results      = em_disco:query(QueryBin),
            %% Each filter returns a list of embryos.
            %% Flatten all filter results into a single list.
            Embryos      = lists:flatten(Results),
            ResponseBody = json:encode(#{<<"embryo_list">> => Embryos}),
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
