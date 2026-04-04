-module(em_disco_mcp_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    initialize_test/1,
    tools_list_test/1,
    search_no_agents_test/1,
    search_with_agent_test/1,
    list_agents_test/1,
    list_capabilities_test/1,
    unknown_method_test/1
]).

all() -> [
    initialize_test,
    tools_list_test,
    search_no_agents_test,
    search_with_agent_test,
    list_agents_test,
    list_capabilities_test,
    unknown_method_test
].

init_per_suite(Config) ->
    Port = em_disco_test_helpers:start_disco(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    em_disco_test_helpers:stop_disco().

%%====================================================================
%% Test cases
%%====================================================================

initialize_test(_Config) ->
    Response = mcp_call(<<"initialize">>, #{}),
    ?assertMatch(#{<<"result">> := _}, Response),
    Result = maps:get(<<"result">>, Response),
    ?assert(maps:is_key(<<"protocolVersion">>, Result)),
    ServerInfo = maps:get(<<"serverInfo">>, Result),
    ?assertEqual(<<"em-disco">>, maps:get(<<"name">>, ServerInfo)),
    ?assertEqual(<<"1.0.0">>, maps:get(<<"version">>, ServerInfo)).

tools_list_test(_Config) ->
    Response = mcp_call(<<"tools/list">>, #{}),
    ?assertMatch(#{<<"result">> := _}, Response),
    Result = maps:get(<<"result">>, Response),
    Tools  = maps:get(<<"tools">>, Result),
    ?assert(is_list(Tools)),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"search">>,            Names)),
    ?assert(lists:member(<<"list_agents">>,       Names)),
    ?assert(lists:member(<<"list_capabilities">>, Names)).

search_no_agents_test(_Config) ->
    Response = mcp_tool(<<"search">>, #{<<"query">> => <<"test">>}),
    Text = get_text_content(Response),
    ?assertEqual(0,  maps:get(<<"count">>,       Text)),
    ?assertEqual([], maps:get(<<"embryo_list">>, Text)).

search_with_agent_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_mcp">>),
    handshake(Conn, <<"agent_mcp">>, [<<"web">>]),

    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">>      => 1,
        <<"method">>  => <<"tools/call">>,
        <<"params">>  => #{
            <<"name">>      => <<"search">>,
            <<"arguments">> => #{<<"query">> => <<"mcp search test">>}
        }
    }),
    post_mcp_async(Body),

    Msg     = em_disco_test_helpers:ws_recv(Conn),
    QueryId = maps:get(<<"id">>, Msg),
    em_disco_test_helpers:ws_send(Conn, #{
        <<"action">> => <<"result">>,
        <<"id">>     => QueryId,
        <<"data">>   => #{<<"type">> => <<"web">>, <<"title">> => <<"MCP Result">>}
    }),

    {200, _, RespBody} = await_mcp(),
    Response = json:decode(RespBody),
    Text = get_text_content(Response),
    ?assertEqual(1, maps:get(<<"count">>, Text)),
    EmbryoList = maps:get(<<"embryo_list">>, Text),
    ?assertEqual(1, length(EmbryoList)),
    [Embryo | _] = EmbryoList,
    ?assertEqual(<<"web">>, maps:get(<<"type">>, Embryo)),

    em_disco_test_helpers:ws_close(Conn).

list_agents_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_list">>),
    handshake(Conn, <<"agent_list">>, [<<"dns">>]),

    Response = mcp_tool(<<"list_agents">>, #{}),
    Text = get_text_content(Response),
    Count  = maps:get(<<"count">>,  Text),
    Agents = maps:get(<<"agents">>, Text),
    ?assert(Count >= 1),
    Names = [maps:get(<<"name">>, A) || A <- Agents],
    ?assert(lists:member(<<"agent_list">>, Names)),

    em_disco_test_helpers:ws_close(Conn).

list_capabilities_test(_Config) ->
    {ok, Conn} = em_disco_test_helpers:ws_connect(<<"agent_caps">>),
    handshake(Conn, <<"agent_caps">>, [<<"unique_mcp_cap">>]),

    Response = mcp_tool(<<"list_capabilities">>, #{}),
    Text = get_text_content(Response),
    Caps = maps:get(<<"capabilities">>, Text),
    ?assert(is_list(Caps)),
    ?assert(lists:member(<<"unique_mcp_cap">>, Caps)),

    em_disco_test_helpers:ws_close(Conn).

unknown_method_test(_Config) ->
    Response = mcp_call(<<"foo/bar">>, #{}),
    ?assertMatch(#{<<"error">> := _}, Response),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

%%====================================================================
%% Helpers
%%====================================================================

mcp_call(Method, Params) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">>      => 1,
        <<"method">>  => Method,
        <<"params">>  => Params
    }),
    {200, _, RespBody} = em_disco_test_helpers:http_post(
        "/mcp", Body, [{<<"content-type">>, <<"application/json">>}]
    ),
    json:decode(RespBody).

mcp_tool(Name, Args) ->
    mcp_call(<<"tools/call">>, #{<<"name">> => Name, <<"arguments">> => Args}).

get_text_content(Response) ->
    Result  = maps:get(<<"result">>,  Response),
    Content = maps:get(<<"content">>, Result),
    [#{<<"text">> := Text}] = Content,
    json:decode(Text).

handshake(Conn, Name, Caps) ->
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"register">>, <<"name">> => Name}),
    _ = em_disco_test_helpers:ws_recv(Conn),
    em_disco_test_helpers:ws_send(Conn, #{<<"action">> => <<"agent_hello">>, <<"capabilities">> => Caps}),
    _ = em_disco_test_helpers:ws_recv(Conn).

post_mcp_async(Body) ->
    Self = self(),
    spawn(fun() ->
        Result = em_disco_test_helpers:http_post(
            "/mcp", Body, [{<<"content-type">>, <<"application/json">>}]
        ),
        Self ! {mcp_result, Result}
    end).

await_mcp() ->
    receive {mcp_result, R} -> R after 6000 -> error(mcp_timeout) end.
