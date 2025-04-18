-module(em_disco_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    % Start the actual discovery service
    em_disco_sup:start_link().

stop(_State) ->
    ok.
