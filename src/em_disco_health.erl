%%%-------------------------------------------------------------------
%%% @doc em_disco_health — trivial Cowboy liveness-check handler.
%%%
%%% Route: GET /health
%%%
%%% Always replies 200 with a plain-text body of `ok'. Used by
%%% deployment smoke tests to confirm the HTTP listener is up.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_health).
-behaviour(cowboy_handler).
-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/plain">>},
        <<"ok">>, Req0),
    {ok, Req, State}.
