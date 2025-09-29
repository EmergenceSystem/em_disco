-module(em_disco_handlers).
-export([handle_register/1, handle_unregister/1, handle_query/1]).

-include_lib("wade/include/wade.hrl").

%% ============================================================================
%% Route Handlers
%% ============================================================================

handle_register(Req) ->
    io:format("handle_register called with Req: ~p~n", [Req]),
    try
        RawBody = get_body(Req),
        io:format("RawBody: ~p~n", [RawBody]),
        FilterInfo = jsx:decode(RawBody, [return_maps]),
        io:format("FilterInfo: ~p~n", [FilterInfo]),
        Url = maps:get(<<"url">>, FilterInfo),
        em_disco:register_filter(Url),
        %% Return a tuple compatible with send_response/4: {Status, Body, Headers}
        {200, jsx:encode(#{<<"status">> => <<"registered">>}), [
            {"Content-Type", "application/json"},
            {"Connection", "close"}  %% Force connection close
        ]}
    catch
        Error:Reason ->
            io:format("Error in handle_register: ~p:~p~n", [Error, Reason]),
            {400, jsx:encode(#{<<"error">> => <<"Invalid request">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}  %% Force connection close
            ]}
    end.

handle_unregister(Req) ->
    try
        RawBody = get_body(Req),
        FilterInfo = jsx:decode(RawBody, [return_maps]),
        Url = maps:get(<<"url">>, FilterInfo),
        em_disco:unregister_filter(Url),
        {200, jsx:encode(#{<<"status">> => <<"unregistered">>}), [
            {"Content-Type", "application/json"},
            {"Connection", "close"}  %% Force connection close
        ]}
    catch
        Error:Reason ->
            io:format("Error in handle_unregister: ~p:~p~n", [Error, Reason]),
            {400, jsx:encode(#{<<"error">> => <<"Invalid request">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}  %% Force connection close
            ]}
    end.

handle_query(Req) ->
    try
        RawBody = get_body(Req),
        AggregatedList = em_disco:query(RawBody),
        Response = jsx:encode(#{<<"embryo_list">> => AggregatedList}),
        {200, Response, [
            {"Content-Type", "application/json"},
            {"Connection", "close"}  %% Force connection close
        ]}
    catch
        Error:Reason ->
            io:format("Error in handle_query: ~p:~p~n", [Error, Reason]),
            {500, jsx:encode(#{<<"error">> => <<"Query failed">>}), [
                {"Content-Type", "application/json"},
                {"Connection", "close"}  %% Force connection close
            ]}
    end.

%% ============================================================================
%% Internal Functions
%% ============================================================================

get_body(Req) ->
    case Req#req.body of
        undefined -> <<"{}">>;
        Body when is_list(Body) -> list_to_binary(Body);
        Body when is_binary(Body) -> Body
    end.

