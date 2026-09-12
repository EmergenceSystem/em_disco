-module(em_disco_mcp_SUITE).
-compile(export_all).

all() -> [initialize_returns_server_info,
          tools_list_returns_three_tools,
          list_agents_empty_by_default,
          unknown_tool_returns_error].

%% NOTE: mirrors em_disco_http_SUITE — full app lifecycle, plain HTTP
%% via inets/httpc (no WS upgrade needed for /mcp POST requests).
init_per_suite(Cfg) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(cowboy),
    application:load(em_disco),
    %% Avoid colliding with the default em_pop gossip TCP port (9100),
    %% which may already be bound by an unrelated running node on the
    %% test host.
    application:set_env(em_disco, gossip_port, 19101),
    {ok, _} = application:ensure_all_started(em_disco),
    Cfg.

end_per_suite(_) ->
    application:stop(em_disco),
    ok.

mcp_post(Body) ->
    Port = application:get_env(em_disco, http_port, 9080),
    {ok, {{_, 200, _}, _, RespBody}} =
        httpc:request(post,
            {"http://127.0.0.1:" ++ integer_to_list(Port) ++ "/mcp",
             [], "application/json", iolist_to_binary(json:encode(Body))},
            [], []),
    json:decode(list_to_binary(RespBody)).

initialize_returns_server_info(_) ->
    Resp = mcp_post(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                       <<"method">> => <<"initialize">>}),
    #{<<"result">> := #{<<"serverInfo">> := #{<<"name">> := <<"em-disco">>}}} = Resp.

tools_list_returns_three_tools(_) ->
    Resp = mcp_post(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                       <<"method">> => <<"tools/list">>}),
    #{<<"result">> := #{<<"tools">> := Tools}} = Resp,
    3 = length(Tools),
    Names = lists:sort([N || #{<<"name">> := N} <- Tools]),
    [<<"list_agents">>, <<"list_capabilities">>, <<"search">>] = Names.

list_agents_empty_by_default(_) ->
    Resp = mcp_post(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
                       <<"method">> => <<"tools/call">>,
                       <<"params">> => #{<<"name">> => <<"list_agents">>}}),
    #{<<"result">> := #{<<"content">> := [#{<<"text">> := Text}]}} = Resp,
    #{<<"count">> := 0, <<"agents">> := []} = json:decode(Text).

unknown_tool_returns_error(_) ->
    Resp = mcp_post(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4,
                       <<"method">> => <<"tools/call">>,
                       <<"params">> => #{<<"name">> => <<"nope">>}}),
    #{<<"error">> := #{<<"code">> := -32601}} = Resp.
