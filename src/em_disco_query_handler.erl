%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP handler for the em_disco super-node query endpoint.
%%%
%%% Route: POST /agent/query
%%%
%%% The super-node has no data of its own. Its value is its large
%%% em_pop peer table, which enables peer discovery for the network.
%%% All direct queries return an empty results list.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_query_handler).
-behaviour(cowboy_handler).
-export([init/2]).

%% @doc Accept any POST body and always return {"results":[]}.
init(Req0, State) ->
    {ok, _, Req1} = cowboy_req:read_body(Req0),
    Req2 = cowboy_req:reply(200,
               #{<<"content-type">> => <<"application/json">>},
               <<"{\"results\":[]}">>,
               Req1),
    {ok, Req2, State}.
