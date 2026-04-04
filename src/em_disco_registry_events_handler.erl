%%%-------------------------------------------------------------------
%%% @doc
%%% SSE Handler for Live Agent Registry Updates
%%%
%%% Serves `GET /registry/events' as a persistent Server-Sent Events
%%% stream. On connection the handler subscribes to
%%% `em_disco_sse_registry', then blocks in a receive loop.
%%%
%%% Each time the registry changes (agent connects or disconnects),
%%% `em_disco_sse_registry:broadcast/0' sends a
%%% `{registry_update, Payload}' message to this process, which
%%% forwards it to the browser as an SSE `data:' frame.
%%%
%%% A 30 s heartbeat comment (`: ping') is sent in the `after' clause
%%% to prevent proxies and load balancers from closing idle connections.
%%%
%%% The browser's native `EventSource' API reconnects automatically on
%%% disconnect, so no client-side retry logic is needed.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_registry_events_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Open an SSE stream and loop until the browser disconnects.
%%
%% Sends the current registry state immediately on connection (via an
%% initial `em_disco_sse_registry:broadcast/0' call), then waits for
%% `{registry_update, Payload}' messages from `em_disco_sse_registry'.
%% @end
%%--------------------------------------------------------------------
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>                 => <<"text/event-stream">>,
        <<"cache-control">>                => <<"no-cache">>,
        <<"connection">>                   => <<"keep-alive">>,
        <<"access-control-allow-origin">>  => <<"*">>
    }, Req0),
    %% Subscribe before broadcast so we don't miss the initial push
    em_disco_sse_registry:subscribe(),
    em_disco_sse_registry:broadcast(),
    loop(Req, State).

%% @private
%% @doc Receive loop — blocks until the connection is closed.
%% @end
-spec loop(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
loop(Req, State) ->
    receive
        {registry_update, Payload} ->
            cowboy_req:stream_body(
                <<"data: ", Payload/binary, "\n\n">>, nofin, Req),
            loop(Req, State)
    after 30000 ->
        %% Keepalive — SSE comment lines are ignored by EventSource
        cowboy_req:stream_body(<<": ping\n\n">>, nofin, Req),
        loop(Req, State)
    end.
