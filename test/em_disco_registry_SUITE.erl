-module(em_disco_registry_SUITE).
-compile(export_all).

all() -> [register_lookup_unregister].

%% NOTE: unlink/1 after start_link/0 is required in this Common Test
%% setup (OTP 28 / rebar3 3.25.0): init_per_suite and the test case
%% run in different processes, and the process that ran init_per_suite
%% is killed once it returns. Because that kill is not `normal`, it
%% would propagate through the start_link/0 link and take the
%% registry gen_server down with it before the test case runs.
%% Verified via a minimal repro suite. Unlinking preserves the public
%% API (still started via start_link/0, matching how em_disco_sup
%% starts it as a permanent supervised child) while decoupling its
%% lifetime from this ephemeral CT process.
init_per_suite(C) ->
    {ok, Pid} = em_disco_registry:start_link(),
    unlink(Pid),
    C.

register_lookup_unregister(_) ->
    Id = <<"abc">>, Self = self(),
    ok = em_disco_registry:register(Id, Self),
    {ok, Self} = em_disco_registry:lookup(Id),
    ok = em_disco_registry:unregister(Id),
    error = em_disco_registry:lookup(Id).
