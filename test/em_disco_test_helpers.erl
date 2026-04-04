-module(em_disco_test_helpers).

-export([
    start_disco/0,
    stop_disco/0,
    disco_port/0,
    issue_token/1,
    ws_connect/1,
    ws_send/2,
    ws_recv/1,
    ws_close/1,
    ws_pid/1,
    http_post/3,
    http_get/1
]).

-define(TIMEOUT, 5000).
-define(TEST_SECRET, <<"test-secret-for-ct">>).

start_disco() ->
    application:set_env(em_disco, port, 0),
    application:set_env(em_disco, jwt_secret, ?TEST_SECRET),
    application:set_env(em_disco, rate_limit_per_second, 100),
    application:set_env(em_disco, rate_limit_burst, 100),
    application:set_env(em_disco, rate_limit_localhost, 10000),
    application:set_env(em_disco, ws_idle_timeout, 60000),
    application:set_env(em_disco, query_timeout_ms, 2000),
    application:set_env(jose, json_module, jose_json_otp),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(em_disco),
    ranch:get_port(disco_listener).

stop_disco() ->
    application:stop(em_disco),
    ok.

disco_port() ->
    ranch:get_port(disco_listener).

issue_token(AgentName) ->
    em_disco_auth:issue(AgentName, ?TEST_SECRET).

%% Returns an opaque connection map. Pass it to ws_send/ws_recv/ws_close.
ws_connect(AgentName) ->
    Port = disco_port(),
    Token = issue_token(AgentName),
    Path = <<"/ws?token=", Token/binary>>,
    {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(ConnPid, ?TIMEOUT),
    StreamRef = gun:ws_upgrade(ConnPid, Path),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
            {ok, #{pid => ConnPid, stream => StreamRef}}
    after ?TIMEOUT ->
        gun:close(ConnPid),
        error(ws_upgrade_timeout)
    end.

ws_send(#{pid := Pid, stream := Ref}, Data) when is_map(Data) ->
    gun:ws_send(Pid, Ref, {text, json:encode(Data)}).

ws_recv(#{pid := Pid}) ->
    receive
        {gun_ws, Pid, _StreamRef, {text, Frame}} ->
            json:decode(Frame)
    after ?TIMEOUT ->
        error(ws_recv_timeout)
    end.

ws_close(#{pid := Pid}) ->
    gun:close(Pid).

%% Extract raw gun pid (for direct gun_ws receive matching in tests)
ws_pid(#{pid := Pid}) -> Pid.

http_post(Path, Body, Headers) ->
    Port = disco_port(),
    {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(ConnPid, ?TIMEOUT),
    StreamRef = gun:post(ConnPid, Path, Headers, Body),
    {response, _, Status, RespHeaders} = gun:await(ConnPid, StreamRef, ?TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?TIMEOUT),
    gun:close(ConnPid),
    {Status, RespHeaders, RespBody}.

http_get(Path) ->
    Port = disco_port(),
    {ok, ConnPid} = gun:open("localhost", Port, #{protocols => [http]}),
    {ok, http} = gun:await_up(ConnPid, ?TIMEOUT),
    StreamRef = gun:get(ConnPid, Path),
    {response, _, Status, RespHeaders} = gun:await(ConnPid, StreamRef, ?TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?TIMEOUT),
    gun:close(ConnPid),
    {Status, RespHeaders, RespBody}.
