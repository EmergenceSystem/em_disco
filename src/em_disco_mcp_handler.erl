%%%-------------------------------------------------------------------
%%% @doc
%%% MCP Server Handler for em_disco
%%%
%%% Implements the Model Context Protocol (MCP) Streamable HTTP
%%% transport (spec 2025-03-26) on a single /mcp endpoint.
%%%
%%% Compatible with Claude, OpenAI, Cursor, VS Code and any other
%%% MCP-capable LLM client.
%%%
%%% === Transport ===
%%%
%%%   POST /mcp  Content-Type: application/json
%%%     → single JSON-RPC response   (Accept: application/json)
%%%     → SSE stream                  (Accept: text/event-stream)
%%%
%%%   GET  /mcp
%%%     → SSE stream for server-initiated notifications (optional,
%%%       not required by most clients)
%%%
%%% === JSON-RPC methods exposed ===
%%%
%%%   initialize        → server info + capabilities declaration
%%%   notifications/initialized → ack (no-op)
%%%   tools/list        → list of available tools
%%%   tools/call        → invoke a tool
%%%
%%% === Tools ===
%%%
%%%   search(query, capabilities?)
%%%       Runs a query against connected Emergence agents.
%%%       capabilities: optional array of strings to route only to
%%%       matching agents. Omit for broadcast to all agents.
%%%
%%%   list_agents()
%%%       Returns all currently connected agents with their name,
%%%       capabilities and connection timestamp.
%%%
%%%   list_capabilities()
%%%       Returns the deduplicated list of all capabilities currently
%%%       offered by connected agents.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_mcp_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MCP_VERSION,    <<"2025-03-26">>).
-define(SERVER_NAME,    <<"em-disco">>).
-define(SERVER_VERSION, <<"1.0.0">>).

%%====================================================================
%% Cowboy entry point
%%====================================================================

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    handle(Method, Req0, State).

%% GET /mcp — optional SSE channel for server notifications
handle(<<"GET">>, Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>                 => <<"text/event-stream">>,
        <<"cache-control">>                => <<"no-cache">>,
        <<"connection">>                   => <<"keep-alive">>,
        <<"access-control-allow-origin">>  => <<"*">>
    }, Req0),
    %% Send endpoint event as required by MCP Streamable HTTP spec.
    send_sse(Req, <<"endpoint">>, <<"/mcp">>),
    %% Keep the connection open — clients will POST requests separately.
    %% In a full implementation this would be a gen_server keeping the
    %% connection alive. For now, close cleanly after the endpoint event.
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State};

%% POST /mcp — main JSON-RPC entrypoint
handle(<<"POST">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Accept = cowboy_req:header(<<"accept">>, Req1, <<"application/json">>),
    UseSSE = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,

    case parse_jsonrpc(Body) of
        {ok, Requests} when is_list(Requests) ->
            %% Batch request
            Responses = [dispatch(R) || R <- Requests],
            reply_json(json:encode(Responses), Req1, State);
        {ok, Request} ->
            case UseSSE of
                true  -> handle_sse(Request, Req1, State);
                false -> handle_json(Request, Req1, State)
            end;
        {error, _} ->
            Err = error_response(null, -32700, <<"Parse error">>),
            reply_json(json:encode(Err), Req1, State)
    end;

handle(<<"OPTIONS">>, Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State};

handle(_, Req0, State) ->
    Req = cowboy_req:reply(405,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(#{<<"error">> => <<"method not allowed">>}), Req0),
    {ok, Req, State}.

%%====================================================================
%% Response modes
%%====================================================================

%% Plain JSON response — single request/response
handle_json(Request, Req0, State) ->
    Response = dispatch(Request),
    reply_json(json:encode(Response), Req0, State).

%% SSE response — stream one or more events then close
handle_sse(Request, Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>                => <<"text/event-stream">>,
        <<"cache-control">>               => <<"no-cache">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Req0),
    Response = dispatch(Request),
    send_sse(Req, <<"message">>, iolist_to_binary(json:encode(Response))),
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State}.

reply_json(Body, Req0, State) ->
    Req = cowboy_req:reply(200,
        #{<<"content-type">>                => <<"application/json">>,
          <<"access-control-allow-origin">> => <<"*">>},
        Body, Req0),
    {ok, Req, State}.

%%====================================================================
%% JSON-RPC dispatch
%%====================================================================

-spec dispatch(map()) -> map().
dispatch(#{<<"method">> := <<"initialize">>, <<"id">> := Id}) ->
    result(Id, #{
        <<"protocolVersion">> => ?MCP_VERSION,
        <<"serverInfo">>      => #{
            <<"name">>    => ?SERVER_NAME,
            <<"version">> => ?SERVER_VERSION
        },
        <<"capabilities">> => #{
            <<"tools">> => #{<<"listChanged">> => false}
        }
    });

dispatch(#{<<"method">> := <<"notifications/initialized">>}) ->
    %% Notification — no response needed, return null for internal use.
    null;

dispatch(#{<<"method">> := <<"tools/list">>, <<"id">> := Id}) ->
    result(Id, #{<<"tools">> => tools_schema()});

dispatch(#{<<"method">> := <<"tools/call">>,
           <<"id">>     := Id,
           <<"params">> := #{<<"name">> := Name, <<"arguments">> := Args}}) ->
    call_tool(Id, Name, Args);

dispatch(#{<<"method">> := <<"tools/call">>,
           <<"id">>     := Id,
           <<"params">> := #{<<"name">> := Name}}) ->
    call_tool(Id, Name, #{});

dispatch(#{<<"id">> := Id, <<"method">> := Method}) ->
    error_response(Id, -32601,
        iolist_to_binary(["Method not found: ", Method]));

dispatch(_) ->
    error_response(null, -32600, <<"Invalid Request">>).

%%====================================================================
%% Tool implementations
%%====================================================================

-spec call_tool(term(), binary(), map()) -> map().
call_tool(Id, <<"search">>, Args) ->
    Query = maps:get(<<"query">>, Args, <<>>),
    case Query of
        <<>> ->
            error_response(Id, -32602, <<"Missing required argument: query">>);
        _ ->
            Caps    = caps_from_args(Args),
            Body    = iolist_to_binary(json:encode(#{
                          <<"query">> => Query,
                          <<"value">> => Query
                      })),
            Results = em_disco:query(Body, Caps),
            Embryos = lists:flatmap(fun
                (L) when is_list(L) -> L;
                (M) when is_map(M)  -> [M];
                (_)                  -> []
            end, Results),
            result(Id, #{
                <<"content">> => [#{
                    <<"type">> => <<"text">>,
                    <<"text">> => iolist_to_binary(json:encode(#{
                        <<"query">>       => Query,
                        <<"capabilities">> => Caps,
                        <<"count">>       => length(Embryos),
                        <<"embryo_list">> => Embryos
                    }))
                }]
            })
    end;

call_tool(Id, <<"list_agents">>, _Args) ->
    Agents = em_disco:list_agents(),
    Formatted = [#{
        <<"name">>         => Name,
        <<"capabilities">> => Caps,
        <<"connected_at">> => ConnectedAt
    } || #{name := Name, capabilities := Caps,
           connected_at := ConnectedAt} <- Agents],
    result(Id, #{
        <<"content">> => [#{
            <<"type">> => <<"text">>,
            <<"text">> => iolist_to_binary(json:encode(#{
                <<"count">>  => length(Formatted),
                <<"agents">> => Formatted
            }))
        }]
    });

call_tool(Id, <<"list_capabilities">>, _Args) ->
    Caps = em_disco:list_capabilities(),
    result(Id, #{
        <<"content">> => [#{
            <<"type">> => <<"text">>,
            <<"text">> => iolist_to_binary(json:encode(#{
                <<"count">>        => length(Caps),
                <<"capabilities">> => Caps
            }))
        }]
    });

call_tool(Id, Name, _Args) ->
    error_response(Id, -32601,
        iolist_to_binary(["Unknown tool: ", Name])).

%%====================================================================
%% Tools schema
%%====================================================================

tools_schema() ->
    [
        #{
            <<"name">>        => <<"search">>,
            <<"description">> =>
                <<"Search across all connected Emergence agents. "
                  "Returns aggregated results from distributed sources "
                  "(web, RSS, DNS, knowledge bases, APIs…). "
                  "Optionally filter by capabilities to route only to "
                  "relevant agents.">>,
            <<"inputSchema">> => #{
                <<"type">>       => <<"object">>,
                <<"properties">> => #{
                    <<"query">> => #{
                        <<"type">>        => <<"string">>,
                        <<"description">> => <<"The search query">>
                    },
                    <<"capabilities">> => #{
                        <<"type">>        => <<"array">>,
                        <<"items">>       => #{<<"type">> => <<"string">>},
                        <<"description">> =>
                            <<"Optional. Filter agents by capability. "
                              "Example: [\"dns\",\"network\"]. "
                              "Omit to broadcast to all agents.">>
                    }
                },
                <<"required">> => [<<"query">>]
            }
        },
        #{
            <<"name">>        => <<"list_agents">>,
            <<"description">> =>
                <<"List all agents currently connected to this em-disco "
                  "node, with their names, capabilities and connection time.">>,
            <<"inputSchema">> => #{
                <<"type">>       => <<"object">>,
                <<"properties">> => #{}
            }
        },
        #{
            <<"name">>        => <<"list_capabilities">>,
            <<"description">> =>
                <<"Return the deduplicated list of all capabilities "
                  "currently offered by connected agents. "
                  "Use this to discover what kind of searches are available "
                  "before calling search() with capabilities filtering.">>,
            <<"inputSchema">> => #{
                <<"type">>       => <<"object">>,
                <<"properties">> => #{}
            }
        }
    ].

%%====================================================================
%% JSON-RPC helpers
%%====================================================================

-spec result(term(), term()) -> map().
result(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">>      => Id,
      <<"result">>  => Result}.

-spec error_response(term(), integer(), binary()) -> map().
error_response(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">>      => Id,
      <<"error">>   => #{
          <<"code">>    => Code,
          <<"message">> => Message
      }}.

-spec parse_jsonrpc(binary()) -> {ok, map() | list()} | {error, term()}.
parse_jsonrpc(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, invalid_json} end.

-spec caps_from_args(map()) -> [binary()].
caps_from_args(Args) ->
    case maps:get(<<"capabilities">>, Args, []) of
        L when is_list(L) -> [C || C <- L, is_binary(C)];
        _                 -> []
    end.

%%====================================================================
%% SSE helper
%%====================================================================

send_sse(Req, Event, Data) ->
    Frame = <<"event: ", Event/binary, "\ndata: ", Data/binary, "\n\n">>,
    cowboy_req:stream_body(Frame, nofin, Req).

%%====================================================================
%% CORS headers
%%====================================================================

cors_headers() ->
    #{<<"access-control-allow-origin">>  => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> =>
          <<"content-type, accept, authorization">>}.
