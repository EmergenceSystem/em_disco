-module(em_disco_http_SUITE).
-compile(export_all).

all() -> [gossip_route_up].

init_per_suite(Cfg) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(cowboy),
    %% Avoid colliding with the default em_pop gossip TCP port
    %% (9100), which may already be bound by an unrelated running
    %% node on the test host; the gossip TCP listener itself is not
    %% under test here, only the HTTP mount.
    application:load(em_disco),
    application:set_env(em_disco, gossip_port, 19100),
    {ok, _} = application:ensure_all_started(em_disco),
    Cfg.

end_per_suite(_) ->
    application:stop(em_disco),
    ok.

gossip_route_up(_) ->
    Port = application:get_env(em_disco, http_port, 9080),
    {ok, {{_,Status,_}, _, _}} =
        httpc:request(post,
            {"http://127.0.0.1:" ++ integer_to_list(Port) ++ "/pop/gossip",
             [], "application/json", "{}"},
            [], []),
    true = (Status =:= 200 orelse Status =:= 400).  %% mounted, not 404
