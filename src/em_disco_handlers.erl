-module(em_disco_handlers).
-export([handle_register/1, handle_unregister/1, handle_query/1]).

-include_lib("wade/include/wade.hrl").

%% ============================================================================
%% Route Handlers
%% ============================================================================

handle_register(Req) ->
    try
        Body = Req#req.body,
        
        %% Body is already a map (parsed by Wade), no need to decode
        FilterInfo = case Body of
            M when is_map(M) -> M;
            B when is_binary(B) -> jsx:decode(B, [return_maps]);
            B when is_list(B) -> jsx:decode(list_to_binary(B), [return_maps]);
            _ -> #{}
        end,
        
        Url = maps:get(<<"url">>, FilterInfo),
        em_disco:register_filter(Url),
        
        {200, jsx:encode(#{<<"status">> => <<"registered">>}), [
            {"Content-Type", "application/json"},
            {"Connection", "close"}
        ]}
    catch
        Error:Reason ->
            io:format("Error in handle_register: ~p:~p~n", [Error, Reason]),
            {400, jsx:encode(#{<<"error">> => <<"Invalid request">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

handle_unregister(Req) ->
    try
        Body = Req#req.body,
        
        %% Body is already a map (parsed by Wade)
        FilterInfo = case Body of
            M when is_map(M) -> M;
            B when is_binary(B) -> jsx:decode(B, [return_maps]);
            B when is_list(B) -> jsx:decode(list_to_binary(B), [return_maps]);
            _ -> #{}
        end,
        
        Url = maps:get(<<"url">>, FilterInfo),
        em_disco:unregister_filter(Url),
        
        {200, jsx:encode(#{<<"status">> => <<"unregistered">>}), [
            {"Content-Type", "application/json"},
            {"Connection", "close"}
        ]}
    catch
        Error:Reason ->
            io:format("Error in handle_unregister: ~p:~p~n", [Error, Reason]),
            {400, jsx:encode(#{<<"error">> => <<"Invalid request">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

handle_query(Req) ->
    try
        Body = Req#req.body,
        
        %% Extract the query value and convert it to binary for em_disco:query
        QueryValue = case Body of
            M when is_map(M) ->
                %% Get the "value" or "query" field
                case maps:get(<<"value">>, M, undefined) of
                    undefined -> maps:get(<<"query">>, M, <<>>);
                    V -> V
                end;
            B when is_binary(B) -> B;
            B when is_list(B) -> list_to_binary(B);
            _ -> <<>>
        end,
        
        io:format("Querying with value: ~p~n", [QueryValue]),
        
        %% em_disco:query expects a binary string, not a map
        AggregatedList = em_disco:query(QueryValue),
        Response = jsx:encode(#{<<"embryo_list">> => AggregatedList}),
        
        {200, Response, [
            {"Content-Type", "application/json"},
            {"Connection", "close"}
        ]}
    catch
        Error:Reason:Stack ->
            io:format("Error in handle_query: ~p:~p~nStack: ~p~n", [Error, Reason, Stack]),
            {500, jsx:encode(#{<<"error">> => <<"Query failed">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.
