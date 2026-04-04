-module(em_disco_query_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    query_no_agents_test/1,
    query_single_agent_test/1,
    query_two_agents_test/1,
    query_capability_filter_test/1,
    query_empty_body_test/1,
    query_timeout_test/1
]).

all() -> [
    query_no_agents_test,
    query_single_agent_test,
    query_two_agents_test,
    query_capability_filter_test,
    query_empty_body_test,
    query_timeout_test
].

init_per_suite(Config) ->
    _Port = em_disco_test_helpers:start_disco(),
    Config.

end_per_suite(_Config) ->
    em_disco_test_helpers:stop_disco().

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

%% Spawn the HTTP POST in a background process (it blocks until the
%% server resolves the query). The main test process can then handle
%% WS receives, since gun_ws messages go to the connection-owner (main).
post_query_async(Body) ->
    Self = self(),
    spawn(fun() ->
        Result = em_disco_test_helpers:http_post(
            "/query", Body, [{<<"content-type">>, <<"application/json">>}]
        ),
        Self ! {http_result, Result}
    end).

await_http() ->
    receive
        {http_result, Result} -> Result
    after 6000 ->
        error(http_timeout)
    end.

%% Complete the 2-step agent handshake (register + agent_hello).
handshake(Conn, Name, Caps) ->
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"register">>, <<"name">> => Name}),
    _ = em_disco_test_helpers:ws_recv(Conn),
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"agent_hello">>, <<"capabilities">> => Caps}),
    _ = em_disco_test_helpers:ws_recv(Conn).

%% Receive a query dispatch from the server then immediately reply with data.
recv_and_reply(Conn, Data) ->
    Msg     = em_disco_test_helpers:ws_recv(Conn),
    QueryId = maps:get(<<"id">>, Msg),
    em_disco_test_helpers:ws_send(Conn, #{
        <<"action">> => <<"result">>,
        <<"id">>     => QueryId,
        <<"data">>   => Data
    }).

%%====================================================================
%% Test cases
%%====================================================================

%% 1. No agents — expect 200 with empty embryo_list
query_no_agents_test(_Config) ->
    {200, _, Body} = em_disco_test_helpers:http_post(
        "/query",
        json:encode(#{<<"query">> => <<"hello world">>}),
        [{<<"content-type">>, <<"application/json">>}]
    ),
    Response = json:decode(Body),
    ?assertEqual([], maps:get(<<"embryo_list">>, Response)).

%% 2. Single agent — connects, handshakes, receives query, replies, response has 1 embryo
query_single_agent_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_sq">>),
    handshake(Conn, <<"agent_sq">>, [<<"web">>]),

    post_query_async(json:encode(#{<<"query">> => <<"test query">>})),

    recv_and_reply(Conn, #{<<"type">> => <<"web">>, <<"title">> => <<"Test Result">>}),

    {200, _, Body} = await_http(),
    Response = json:decode(Body),
    Embryos  = maps:get(<<"embryo_list">>, Response),
    ?assertEqual(1, length(Embryos)),
    ?assertMatch([#{<<"type">> := <<"web">>, <<"title">> := <<"Test Result">>}], Embryos),

    em_disco_test_helpers:ws_close(Conn).

%% 3. Two agents — both receive the query, both reply, response has 2 embryos
query_two_agents_test(_Config) ->
    {ok, ConnA} = em_disco_test_helpers:ws_connect(<<"agent_qa">>),
    handshake(ConnA, <<"agent_qa">>, [<<"web">>]),

    {ok, ConnB} = em_disco_test_helpers:ws_connect(<<"agent_qb">>),
    handshake(ConnB, <<"agent_qb">>, [<<"rss">>]),

    post_query_async(json:encode(#{<<"query">> => <<"two agent query">>})),

    recv_and_reply(ConnA, #{<<"type">> => <<"web">>,  <<"title">> => <<"Result A">>}),
    recv_and_reply(ConnB, #{<<"type">> => <<"rss">>,  <<"title">> => <<"Result B">>}),

    {200, _, Body} = await_http(),
    Response = json:decode(Body),
    Embryos  = maps:get(<<"embryo_list">>, Response),
    ?assertEqual(2, length(Embryos)),

    em_disco_test_helpers:ws_close(ConnA),
    em_disco_test_helpers:ws_close(ConnB).

%% 4. Capability filter — only matching agent receives the query
query_capability_filter_test(_Config) ->
    {ok, ConnDns} = em_disco_test_helpers:ws_connect(<<"agent_cap_dns">>),
    handshake(ConnDns, <<"agent_cap_dns">>, [<<"dns">>]),

    {ok, ConnRss} = em_disco_test_helpers:ws_connect(<<"agent_cap_rss">>),
    handshake(ConnRss, <<"agent_cap_rss">>, [<<"rss">>]),

    post_query_async(json:encode(#{
        <<"query">>        => <<"test">>,
        <<"capabilities">> => [<<"dns">>]
    })),

    recv_and_reply(ConnDns, #{<<"type">> => <<"dns">>, <<"title">> => <<"DNS Result">>}),

    {200, _, Body} = await_http(),

    %% Verify agent_cap_rss did NOT receive a query frame
    RssPid = em_disco_test_helpers:ws_pid(ConnRss),
    receive
        {gun_ws, RssPid, _, {text, _}} ->
            error(rss_agent_should_not_receive_query)
    after 500 ->
        ok
    end,

    Response = json:decode(Body),
    Embryos  = maps:get(<<"embryo_list">>, Response),
    ?assertEqual(1, length(Embryos)),
    ?assertMatch([#{<<"type">> := <<"dns">>}], Embryos),

    em_disco_test_helpers:ws_close(ConnDns),
    em_disco_test_helpers:ws_close(ConnRss).

%% 5. Empty body (no "query" field) — expect 400
query_empty_body_test(_Config) ->
    {400, _, Body} = em_disco_test_helpers:http_post(
        "/query",
        json:encode(#{}),
        [{<<"content-type">>, <<"application/json">>}]
    ),
    Response = json:decode(Body),
    ?assertEqual(<<"invalid_request">>, maps:get(<<"error">>, Response)).

%% 6. Agent connects and receives the query but never replies;
%%    server times out (2000ms) and returns empty embryo_list.
query_timeout_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_timeout">>),
    handshake(Conn, <<"agent_timeout">>, [<<"web">>]),

    post_query_async(json:encode(#{<<"query">> => <<"timeout query">>})),

    %% Drain the query dispatch so it isn't left in the mailbox,
    %% but intentionally send no result back.
    _ = em_disco_test_helpers:ws_recv(Conn),

    {200, _, Body} = await_http(),
    Response = json:decode(Body),
    ?assertEqual([], maps:get(<<"embryo_list">>, Response)),

    em_disco_test_helpers:ws_close(Conn).
