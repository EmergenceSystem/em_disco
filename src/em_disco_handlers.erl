%%%-------------------------------------------------------------------
%%% @doc HTTP handlers for Emquest Disco routes
%%%-------------------------------------------------------------------
-module(em_disco_handlers).
-export([handle_register/1, handle_unregister/1, handle_query/1]).

-include_lib("wade/include/wade.hrl").

%% ============================================================================
%% Helper function: normalize_body/1
%% Converts different body formats (map, proplist, binary JSON) into a map
%% Returns empty map if the body is invalid.
%% ============================================================================
normalize_body(Body) ->
    case Body of
        %% Already a map
        M when is_map(M) ->
            M;

        %% Proplist: [{key, val}, ...] -> convert to map with binary keys
        List when is_list(List) ->
            maps:from_list(
                [ { 
                    case K of
                        A when is_atom(A) -> atom_to_binary(A, utf8);
                        B when is_binary(B) -> B;
                        _ -> list_to_binary(io_lib:format("~p",[K]))
                    end,
                    case V of
                        Bin when is_binary(Bin) -> Bin;
                        L when is_list(L) -> list_to_binary(L);
                        Other -> list_to_binary(io_lib:format("~p",[Other]))
                    end
                  } 
                  || {K,V} <- List ]
            );

        %% Binary JSON -> decode to map
        Bin when is_binary(Bin) ->
            case catch jsx:decode(Bin, [return_maps]) of
                {'EXIT', _} -> #{};
                Decoded -> Decoded
            end;

        _ -> 
            % Unknown format
            #{}
    end.

%% ============================================================================
%% Handle POST /register
%% Expects body with "url" key (JSON or form-data)
%% ============================================================================
handle_register(Req) ->
    try
        Body = Req#req.body,
        FilterInfo = normalize_body(Body),
        Url = maps:get(<<"url">>, FilterInfo, undefined),
        case Url of
            undefined ->
                {400, jsx:encode(#{<<"error">> => <<"Missing 'url' key">>}), [
                    {"Content-Type", "application/json"},
                    {"Connection", "close"}
                ]};
            _ ->
                em_disco:register_filter(Url),
                {200, jsx:encode(#{<<"status">> => <<"registered">>}), [
                    {"Content-Type", "application/json"},
                    {"Connection", "close"}
                ]}
        end
    catch
        _:_ ->
            {400, jsx:encode(#{<<"error">> => <<"Invalid request">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

%% ============================================================================
%% Handle POST /unregister
%% Expects body with "url" key (JSON or form-data)
%% ============================================================================
handle_unregister(Req) ->
    try
        Body = Req#req.body,
        FilterInfo = normalize_body(Body),
        Url = maps:get(<<"url">>, FilterInfo, undefined),
        case Url of
            undefined ->
                {400, jsx:encode(#{<<"error">> => <<"Missing 'url' key">>}), [
                    {"Content-Type", "application/json"},
                    {"Connection", "close"}
                ]};
            _ ->
                em_disco:unregister_filter(Url),
                {200, jsx:encode(#{<<"status">> => <<"unregistered">>}), [
                    {"Content-Type", "application/json"},
                    {"Connection", "close"}
                ]}
        end
    catch
        _:_ ->
            {400, jsx:encode(#{<<"error">> => <<"Invalid request">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

%% ============================================================================
%% Handle POST /query
%% Expects body with "value" or "query" key (JSON or form-data)
%% Forwards query to em_disco:query as binary
%% ============================================================================
handle_query(Req) ->
    try
        Body = Req#req.body,
        Normalized = normalize_body(Body),

        %% Extract the "value" or "query" key, fallback to empty binary
        QueryValue = case maps:get(<<"value">>, Normalized, undefined) of
            undefined -> maps:get(<<"query">>, Normalized, <<>>);
            V -> V
        end,

        %% Ensure it's binary
        QueryBin = case QueryValue of
            B when is_binary(B) -> B;
            L when is_list(L) -> list_to_binary(L);
            Other -> list_to_binary(io_lib:format("~p", [Other]))
        end,

        %% Call em_disco:query
        AggregatedList = em_disco:query(QueryBin),
        Response = jsx:encode(#{<<"embryo_list">> => AggregatedList}),

        {200, Response, [
            {"Content-Type", "application/json"},
            {"Connection", "close"}
        ]}
    catch
        _:_ ->
            {500, jsx:encode(#{<<"error">> => <<"Query failed">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

