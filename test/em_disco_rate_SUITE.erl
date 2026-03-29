-module(em_disco_rate_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    allow_fresh_ip_test/1,
    exhaust_burst_test/1,
    refill_after_wait_test/1,
    localhost_higher_limit_test/1
]).

all() -> [
    allow_fresh_ip_test,
    exhaust_burst_test,
    refill_after_wait_test,
    localhost_higher_limit_test
].

init_per_suite(Config) ->
    application:set_env(em_disco, rate_limit_per_second, 100),
    application:set_env(em_disco, rate_limit_burst, 5),
    application:set_env(em_disco, rate_limit_localhost, 10000),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    %% Create fresh ETS table for each test
    catch ets:delete(rate_buckets),
    ets:new(rate_buckets, [set, named_table, public]),
    Config.

end_per_testcase(_TC, _Config) ->
    catch ets:delete(rate_buckets),
    ok.

allow_fresh_ip_test(_Config) ->
    ?assertEqual(ok, em_disco_rate:check({192, 168, 1, 1})).

exhaust_burst_test(_Config) ->
    IP = {10, 0, 0, 1},
    %% Burst is 5, so 5 requests should succeed
    lists:foreach(fun(_) ->
        ?assertEqual(ok, em_disco_rate:check(IP))
    end, lists:seq(1, 5)),
    %% 6th request should fail
    ?assertEqual({error, rate_limited}, em_disco_rate:check(IP)).

refill_after_wait_test(_Config) ->
    IP = {10, 0, 0, 2},
    %% Exhaust burst
    lists:foreach(fun(_) -> em_disco_rate:check(IP) end, lists:seq(1, 5)),
    ?assertEqual({error, rate_limited}, em_disco_rate:check(IP)),
    %% Wait 100ms — at 100 tokens/sec, that refills ~10 tokens (capped at burst=5)
    timer:sleep(100),
    ?assertEqual(ok, em_disco_rate:check(IP)).

localhost_higher_limit_test(_Config) ->
    IP = {127, 0, 0, 1},
    %% Localhost burst is 10000, so 100 rapid requests should all succeed
    Results = [em_disco_rate:check(IP) || _ <- lists:seq(1, 100)],
    ?assert(lists:all(fun(R) -> R =:= ok end, Results)).
