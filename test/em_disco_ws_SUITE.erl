-module(em_disco_ws_SUITE).
-compile(export_all).

all() -> [hello_binds_and_registers, hello_bad_sig_rejected].

%% NOTE: mirrors em_disco_http_SUITE's full-app lifecycle so this
%% suite is self-contained regardless of run order — the ws handler
%% needs the real cowboy listener (mounted by em_disco_app:start_http/0)
%% plus em_disco_registry/em_disco_relay wired by em_disco_sup.
init_per_suite(C) ->
    application:ensure_all_started(gun),
    application:load(em_disco),
    %% Avoid colliding with a gossip TCP listener an unrelated node on
    %% the test host may already have bound to (see em_disco_http_SUITE).
    application:set_env(em_disco, gossip_port, 19100),
    {ok, _} = application:ensure_all_started(em_disco),
    C.

end_per_suite(_) ->
    application:stop(em_disco),
    ok.

mk_hello() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Id   = em_pop_crypto:id_of(Pub),
    Name = <<"t_ws">>,
    Sig  = em_pop_crypto:sign(
             em_pop_crypto:canonical_identity(#{id => Id, name => Name}), Priv),
    #{pub => Pub, id => Id,
      frame => json:encode(#{<<"action">> => <<"hello">>,
        <<"name">> => Name, <<"pubkey">> => base64:encode(Pub),
        <<"sig">> => base64:encode(Sig),
        <<"capabilities">> => [<<"search">>]})}.

hello_binds_and_registers(_) ->
    Port = application:get_env(em_disco, http_port, 9080),
    #{id := Id, frame := F} = mk_hello(),
    {ok, C} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(C),
    StreamRef = gun:ws_upgrade(C, "/ws/filter"),
    receive {gun_upgrade,_,_,_,_} -> ok after 2000 -> ct:fail(no_upgrade) end,
    gun:ws_send(C, StreamRef, {text, F}),
    receive {gun_ws,_,_,{text,Ack}} ->
        #{<<"action">> := <<"hello_ok">>} = json:decode(Ack)
    after 2000 -> ct:fail(no_ack) end,
    {ok, _Pid} = em_disco_registry:lookup(Id),
    gun:close(C).

hello_bad_sig_rejected(_) ->
    Port = application:get_env(em_disco, http_port, 9080),
    Bad = json:encode(#{<<"action">> => <<"hello">>, <<"name">> => <<"x">>,
        <<"pubkey">> => base64:encode(<<0:256>>),
        <<"sig">> => base64:encode(<<0:512>>), <<"capabilities">> => []}),
    {ok, C} = gun:open("127.0.0.1", Port), {ok,_} = gun:await_up(C),
    StreamRef = gun:ws_upgrade(C, "/ws/filter"),
    receive {gun_upgrade,_,_,_,_} -> ok after 2000 -> ct:fail(no_upgrade) end,
    gun:ws_send(C, StreamRef, {text, Bad}),
    receive {gun_ws,_,_,{text,Ack}} ->
        #{<<"action">> := <<"error">>} = json:decode(Ack)
    after 2000 -> ct:fail(no_ack) end,
    gun:close(C).
