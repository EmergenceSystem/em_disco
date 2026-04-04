-module(em_disco_sse_registry_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0,
         init_per_testcase/2, end_per_testcase/2,
         subscribe_receives_broadcast/1, dead_subscriber_removed/1]).

all() -> [subscribe_receives_broadcast, dead_subscriber_removed].

init_per_testcase(_TestCase, Config) ->
    ets:new(agent_registry, [set, named_table, public, {read_concurrency, true}]),
    {ok, Srv} = em_disco_sse_registry:start_link(),
    [{server, Srv} | Config].

end_per_testcase(_TestCase, Config) ->
    Srv = proplists:get_value(server, Config),
    gen_server:stop(Srv),
    catch ets:delete(agent_registry),
    ok.

subscribe_receives_broadcast(Config) ->
    _Srv = proplists:get_value(server, Config),
    ok = em_disco_sse_registry:subscribe(),
    ok = em_disco_sse_registry:broadcast(),
    receive
        {registry_update, Payload} when is_binary(Payload) -> ok
    after 1000 ->
        ct:fail(no_registry_update_received)
    end.

dead_subscriber_removed(Config) ->
    _Srv = proplists:get_value(server, Config),
    Sub = spawn(fun() -> em_disco_sse_registry:subscribe(), timer:sleep(5000) end),
    timer:sleep(50),
    exit(Sub, kill),
    timer:sleep(50),
    ok = em_disco_sse_registry:broadcast(),
    receive
        {registry_update, _} -> ct:fail(unexpected_message)
    after 200 ->
        ok
    end.
