-module(em_disco_ws_abuse_SUITE).
-compile(export_all).

all() -> [sixth_conn_within_window_rejected].

%% NOTE: mirrors em_disco_ws_SUITE's full-app lifecycle (real cowboy
%% listener + em_disco_registry/em_disco_relay wired by em_disco_sup).
%% Run standalone: whole-suite `rebar3 ct` has a pre-existing
%% cross-suite app-already-started collision — see em_disco_ws_SUITE.
init_per_suite(C) ->
    application:ensure_all_started(gun),
    application:load(em_disco),
    %% Distinct gossip port so this suite doesn't collide with a
    %% gossip listener another suite/node on the test host may hold.
    application:set_env(em_disco, gossip_port, 19101),
    {ok, _} = application:ensure_all_started(em_disco),
    C.

end_per_suite(_) ->
    application:stop(em_disco),
    ok.

%% The abuse control is `?CONN_RATE_CAPACITY = 5' upgrades per source
%% IP per `?CONN_RATE_WINDOW_SECONDS = 60' window (em_disco_ws.erl).
%% All gun connections here originate from the loopback address, so
%% they share one token bucket: the first 5 upgrade normally, the 6th
%% must be rejected with a plain HTTP 429 instead of a WS upgrade.
sixth_conn_within_window_rejected(_) ->
    Port = application:get_env(em_disco, http_port, 9080),
    Conns = [connect_and_upgrade(Port) || _ <- lists:seq(1, 5)],
    {C6, _} = connect(Port),
    _ = gun:ws_upgrade(C6, "/ws/filter"),
    receive
        {gun_response, _, _, _, Status, _} ->
            429 = Status;
        {gun_upgrade, _, _, _, _} ->
            ct:fail(sixth_conn_should_be_rejected)
    after 2000 ->
        ct:fail(no_response)
    end,
    gun:close(C6),
    lists:foreach(fun(C) -> gun:close(C) end, Conns).

%% @private Open a plain connection (no upgrade yet).
connect(Port) ->
    {ok, C} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(C),
    {C, undefined}.

%% @private Open a connection and confirm it upgrades to WS.
connect_and_upgrade(Port) ->
    {C, _} = connect(Port),
    StreamRef = gun:ws_upgrade(C, "/ws/filter"),
    receive
        {gun_upgrade, C, StreamRef, _, _} -> ok
    after 2000 -> ct:fail(no_upgrade)
    end,
    C.
