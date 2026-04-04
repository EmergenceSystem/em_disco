%%%-------------------------------------------------------------------
%%% @doc
%%% em_disco OTP Application Callback
%%%
%%% Entry point for the `em_disco' OTP application.
%%% Starts the top-level supervisor (`em_disco_sup') which initialises
%%% the ETS tables and the Cowboy HTTP/WebSocket listener.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_app).
-behaviour(application).

-export([start/2, stop/1]).

%%--------------------------------------------------------------------
%% @doc Starts the em_disco application.
%%
%% Called automatically by the OTP application controller.
%% Delegates to `em_disco_sup:start_link/0'.
%%
%% @param StartType Start type as defined by the OTP application behaviour.
%% @param StartArgs Arguments from the `mod' key of the app descriptor
%%                  (unused).
%% @return `{ok, Pid}' where `Pid' is the top-level supervisor.
%% @end
%%--------------------------------------------------------------------
start(_StartType, _StartArgs) ->
    logger:add_primary_filter(no_progress,
        {fun logger_filters:progress/2, stop}),
    em_disco_sup:start_link().

%%--------------------------------------------------------------------
%% @doc Stops the em_disco application.
%%
%% Called automatically by the OTP application controller after the
%% supervision tree has been shut down.
%%
%% @param State Application state returned by `start/2' (unused).
%% @return `ok'.
%% @end
%%--------------------------------------------------------------------
stop(_State) ->
    cowboy:stop_listener(disco_listener),
    ok.
