-module(em_disco_relay_SUITE).
-compile(export_all).

all() -> [relay_roundtrip, relay_unknown_peer].

%% NOTE: unlink/1 after start_link/0 is required in this Common Test
%% setup (OTP 28 / rebar3 3.25.0) — see em_disco_registry_SUITE for
%% the full explanation. init_per_suite and the test case run in
%% different processes; the process that ran init_per_suite is killed
%% (non-normal) once it returns, which would otherwise propagate
%% through the start_link/0 link and take the gen_server down before
%% the test case runs.
init_per_suite(C) ->
    {ok, RegPid} = em_disco_registry:start_link(),
    unlink(RegPid),
    {ok, RelayPid} = em_disco_relay:start_link(),
    unlink(RelayPid),
    [{registry_pid, RegPid}, {relay_pid, RelayPid} | C].

end_per_suite(C) ->
    gen_server:stop(proplists:get_value(relay_pid, C)),
    gen_server:stop(proplists:get_value(registry_pid, C)),
    ok.

relay_roundtrip(_) ->
    Id = <<"peer1">>,
    %% Fake filter process: on {relay_query,QId,_} reply via deliver/2.
    Filter = spawn(fun F() ->
        receive {relay_query, QId, _Q} ->
            em_disco_relay:deliver(QId,
                #{<<"results">> => [], <<"signer_id">> => <<"s">>,
                  <<"signature">> => <<"sig">>}),
            F()
        end end),
    ok = em_disco_registry:register(Id, Filter,
            #{name => <<"filter1">>, capabilities => [<<"search">>]}),
    {ok, Resp} = em_disco_relay:query(Id, <<"hello">>, 2000),
    #{<<"signer_id">> := <<"s">>} = Resp,
    ok = em_disco_registry:unregister(Id).

relay_unknown_peer(_) ->
    {error, not_found} = em_disco_relay:query(<<"nope">>, <<"q">>, 500).
