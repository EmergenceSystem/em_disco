-module(em_disco_ws_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    register_and_hello_test/1,
    hello_before_register_test/1,
    duplicate_name_test/1,
    name_mismatch_test/1,
    no_token_rejected_test/1,
    bad_token_rejected_test/1
]).

all() -> [
    register_and_hello_test,
    hello_before_register_test,
    duplicate_name_test,
    name_mismatch_test,
    no_token_rejected_test,
    bad_token_rejected_test
].

init_per_suite(Config) ->
    Port = em_disco_test_helpers:start_disco(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    em_disco_test_helpers:stop_disco().

register_and_hello_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_a">>),
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"register">>, <<"name">> => <<"agent_a">>}),
    Reply1 = em_disco_test_helpers:ws_recv(Conn),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Reply1)),
    ?assertEqual(<<"registered">>, maps:get(<<"action">>, Reply1)),

    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"agent_hello">>, <<"capabilities">> => [<<"dns">>]}),
    Reply2 = em_disco_test_helpers:ws_recv(Conn),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Reply2)),
    ?assertEqual(<<"agent_registered">>, maps:get(<<"action">>, Reply2)),

    em_disco_test_helpers:ws_close(Conn).

hello_before_register_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_b">>),
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"agent_hello">>, <<"capabilities">> => [<<"dns">>]}),
    Reply = em_disco_test_helpers:ws_recv(Conn),
    ?assertMatch(#{<<"error">> := _}, Reply),
    em_disco_test_helpers:ws_close(Conn).

duplicate_name_test(_Config) ->
    %% First agent registers successfully
    {ok, Conn1} = em_disco_test_helpers:ws_connect(<<"agent_dup">>),
    em_disco_test_helpers:ws_send(Conn1, #{<<"action">> => <<"register">>, <<"name">> => <<"agent_dup">>}),
    _ = em_disco_test_helpers:ws_recv(Conn1),
    em_disco_test_helpers:ws_send(Conn1, #{<<"action">> => <<"agent_hello">>, <<"capabilities">> => [<<"test">>]}),
    _ = em_disco_test_helpers:ws_recv(Conn1),

    %% Second agent with same name is rejected
    {ok, Conn2} = em_disco_test_helpers:ws_connect(<<"agent_dup">>),
    em_disco_test_helpers:ws_send(Conn2, #{<<"action">> => <<"register">>, <<"name">> => <<"agent_dup">>}),
    _ = em_disco_test_helpers:ws_recv(Conn2),
    em_disco_test_helpers:ws_send(Conn2, #{<<"action">> => <<"agent_hello">>, <<"capabilities">> => [<<"test">>]}),
    Reply = em_disco_test_helpers:ws_recv(Conn2),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, Reply)),
    ?assertEqual(<<"name_taken">>, maps:get(<<"reason">>, Reply)),

    em_disco_test_helpers:ws_close(Conn1),
    em_disco_test_helpers:ws_close(Conn2).

name_mismatch_test(_Config) ->
    %% Token is for "agent_x" but register says "agent_y"
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_x">>),
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"register">>, <<"name">> => <<"agent_y">>}),
    Reply = em_disco_test_helpers:ws_recv(Conn),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, Reply)),
    ?assertEqual(<<"name_mismatch">>, maps:get(<<"reason">>, Reply)),
    em_disco_test_helpers:ws_close(Conn).

no_token_rejected_test(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(ConnPid, 5000),
    StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
    receive
        {gun_response, ConnPid, StreamRef, _, 401, _} -> ok;
        {gun_upgrade, ConnPid, StreamRef, _, _} -> error(should_have_rejected)
    after 5000 -> error(timeout)
    end,
    gun:close(ConnPid).

bad_token_rejected_test(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(ConnPid, 5000),
    StreamRef = gun:ws_upgrade(ConnPid, "/ws?token=invalid.jwt.token"),
    receive
        {gun_response, ConnPid, StreamRef, _, 401, _} -> ok;
        {gun_upgrade, ConnPid, StreamRef, _, _} -> error(should_have_rejected)
    after 5000 -> error(timeout)
    end,
    gun:close(ConnPid).
