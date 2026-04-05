%%%-------------------------------------------------------------------
%%% @doc em_disco OTP application callback module.
%%%
%%% Entry point for the em_disco application. Delegates startup to
%%% {@link em_disco_sup}, which initialises ETS tables and starts the
%%% Cowboy HTTP/WebSocket listener.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_app).
-behaviour(application).

-export([start/2, stop/1]).

%%--------------------------------------------------------------------
%% @doc Start the em_disco application.
%%
%% Called automatically by the OTP application controller.
%% Delegates to {@link em_disco_sup:start_link/0}.
%% @end
%%--------------------------------------------------------------------
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    logger:add_primary_filter(no_progress,
        {fun logger_filters:progress/2, stop}),
    em_disco_sup:start_link().

%%--------------------------------------------------------------------
%% @doc Stop the em_disco application.
%%
%% Stops the Cowboy listener. Called automatically by the OTP
%% application controller after the supervision tree has been shut down.
%% @end
%%--------------------------------------------------------------------
-spec stop(term()) -> ok.
stop(_State) ->
    cowboy:stop_listener(disco_listener),
    ok.
