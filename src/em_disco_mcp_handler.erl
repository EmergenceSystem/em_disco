%%%-------------------------------------------------------------------
%%% @doc MCP Streamable HTTP handler for em_disco.
%%%
%%% Implements the Model Context Protocol (MCP) Streamable HTTP
%%% transport (spec 2025-03-26) on a single /mcp endpoint.
%%%
%%% Compatible with Claude, OpenAI, Cursor, VS Code and any other
%%% MCP-capable LLM client.
%%%
%%% Restored after the Phase 3 em_pop rewrite dropped this module.
%%% The tools below now read from `em_disco_registry' (peer_id ->
%%% {ws_pid, #{name, capabilities}}) and fan queries out over
%%% `em_disco_relay:query/3' instead of the old, now-removed
%%% `em_disco:query/2', `em_disco:list_agents/0' and
%%% `em_disco:list_capabilities/0'.
%%%
%%% === Transport ===
%%%
%%%   POST /mcp  Content-Type: application/json
%%%     -> single JSON-RPC response   (Accept: application/json)
%%%     -> SSE stream                  (Accept: text/event-stream)
%%%
%%%   GET  /mcp
%%%     -> SSE stream for server-initiated notifications (optional,
%%%        not required by most clients)
%%%
%%% === JSON-RPC methods exposed ===
%%%
%%%   initialize                 -> server info + capabilities declaration
%%%   notifications/initialized  -> ack (no-op)
%%%   tools/list                 -> list of available tools
%%%   tools/call                 -> invoke a tool
%%%
%%% === Tools ===
%%%
%%%   search(query, capabilities?)
%%%       Fans the query out to every connected filter (optionally
%%%       restricted to filters advertising a matching capability)
%%%       and aggregates their embryo results.
%%%
%%%   list_agents()
%%%       Returns all currently connected filters with their name and
%%%       capabilities.
%%%
%%%   list_capabilities()
%%%       Returns the deduplicated list of all capabilities currently
%%%       advertised by connected filters.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_mcp_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MCP_VERSION,    <<"2025-03-26">>).
-define(SERVER_NAME,    <<"em-disco">>).
-define(SERVER_VERSION, <<"1.0.0">>).

%% Matches the "10 req/s per IP, burst 30" budget documented in
%% PROTOCOL.md for em_disco's public HTTP endpoints.
-define(RATE_CAPACITY, 30).
-define(RATE_WINDOW_SECONDS, 3).

%% Per-peer timeout when fanning a search query out over em_disco_relay.
-define(SEARCH_TIMEOUT_MS, 5000).

%%====================================================================
%% Cowboy entry point
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Cowboy request entry point for `GET /mcp' and `POST /mcp'.
%%
%% Checks the rate limit then routes to `handle/3'. CORS preflight
%% (`OPTIONS') is handled without rate limiting.
%% @end
%%--------------------------------------------------------------------
init(Req0, State) ->
    Peer = peer_key(Req0),
    case em_disco_ratelimit:allow(Peer, ?RATE_CAPACITY, ?RATE_WINDOW_SECONDS) of
        false ->
            Req = cowboy_req:reply(429,
                #{<<"content-type">> => <<"application/json">>,
                  <<"retry-after">> => <<"1">>},
                json:encode(#{<<"error">> => <<"rate_limited">>}), Req0),
            {ok, Req, State};
        true ->
            Method = cowboy_req:method(Req0),
            handle(Method, Req0, State)
    end.

%% @private
%% @doc Source-IP resolution for the rate limiter: prefer the
%% `cf-connecting-ip' header (set by the Cloudflare tunnel), falling
%% back to the raw socket peer address. Mirrors em_disco_ws.
%% @end
-spec peer_key(cowboy_req:req()) -> binary().
peer_key(Req) ->
    case cowboy_req:header(<<"cf-connecting-ip">>, Req, undefined) of
        undefined ->
            {IP, _Port} = cowboy_req:peer(Req),
            list_to_binary(inet:ntoa(IP));
        CfIp -> CfIp
    end.

%% @private
%% @doc Open an SSE stream and send the `endpoint' event.
%%
%% Required by the MCP Streamable HTTP spec to announce the POST
%% endpoint to the client. The stream is closed immediately after —
%% clients POST their JSON-RPC requests separately.
%% @end
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

%% @private
%% @doc Parse the JSON-RPC body and dispatch.
%%
%% Checks the `Accept' header to decide the response mode: plain JSON
%% (`application/json') or SSE (`text/event-stream'). Batch requests
%% (JSON arrays) always use plain JSON regardless of `Accept'.
%% @end
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

%% @private
%% @doc Dispatch a single JSON-RPC request and reply with plain JSON.
%% @end
handle_json(Request, Req0, State) ->
    Response = dispatch(Request),
    reply_json(json:encode(Response), Req0, State).

%% @private
%% @doc Dispatch a single JSON-RPC request and stream the response as
%% a single SSE `message' event.
%% @end
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

%% @private
%% @doc Send a 200 JSON response with CORS headers.
%% @end
reply_json(Body, Req0, State) ->
    Req = cowboy_req:reply(200,
        #{<<"content-type">>                => <<"application/json">>,
          <<"access-control-allow-origin">> => <<"*">>},
        Body, Req0),
    {ok, Req, State}.

%%====================================================================
%% JSON-RPC dispatch
%%====================================================================

%% @private
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

%% @private
-spec call_tool(term(), binary(), map()) -> map().
call_tool(Id, <<"search">>, Args) ->
    Query = maps:get(<<"query">>, Args, <<>>),
    case Query of
        <<>> ->
            error_response(Id, -32602, <<"Missing required argument: query">>);
        _ ->
            ReqCaps = caps_from_args(Args),
            Body    = iolist_to_binary(json:encode(#{
                          <<"query">> => Query,
                          <<"value">> => Query
                      })),
            Targets = [PeerId || {PeerId, Info} <- em_disco_registry:list(),
                                  matches_capabilities(Info, ReqCaps)],
            Embryos = fanout_query(Targets, Body),
            result(Id, #{
                <<"content">> => [#{
                    <<"type">> => <<"text">>,
                    <<"text">> => iolist_to_binary(json:encode(#{
                        <<"query">>       => Query,
                        <<"capabilities">> => ReqCaps,
                        <<"count">>       => length(Embryos),
                        <<"embryo_list">> => Embryos
                    }))
                }]
            })
    end;

call_tool(Id, <<"list_agents">>, _Args) ->
    Formatted = [#{
        <<"name">>         => maps:get(name, Info, null),
        <<"capabilities">> => maps:get(capabilities, Info, [])
    } || {_PeerId, Info} <- em_disco_registry:list()],
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
    AllCaps = lists:usort(lists:flatmap(
        fun({_PeerId, Info}) -> maps:get(capabilities, Info, []) end,
        em_disco_registry:list())),
    result(Id, #{
        <<"content">> => [#{
            <<"type">> => <<"text">>,
            <<"text">> => iolist_to_binary(json:encode(#{
                <<"count">>        => length(AllCaps),
                <<"capabilities">> => AllCaps
            }))
        }]
    });

call_tool(Id, Name, _Args) ->
    error_response(Id, -32601,
        iolist_to_binary(["Unknown tool: ", Name])).

%%====================================================================
%% Fan-out search helpers
%%====================================================================

%% @private No requested capabilities means broadcast to every
%% connected peer; otherwise the peer must advertise at least one of
%% the requested capabilities.
-spec matches_capabilities(map(), [binary()]) -> boolean().
matches_capabilities(_Info, []) -> true;
matches_capabilities(#{capabilities := PeerCaps}, ReqCaps) ->
    lists:any(fun(C) -> lists:member(C, PeerCaps) end, ReqCaps);
matches_capabilities(_Info, _ReqCaps) -> false.

%% @private
%% @doc Query every target peer concurrently via `em_disco_relay',
%% dropping peers that time out, disconnect mid-flight, or return no
%% embryos, and aggregate the rest into a single flat list.
%% @end
-spec fanout_query([term()], binary()) -> [map()].
fanout_query(Targets, Body) ->
    Self = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() ->
            Self ! {Ref, em_disco_relay:query(PeerId, Body, ?SEARCH_TIMEOUT_MS)}
        end),
        Ref
    end || PeerId <- Targets],
    Results = [receive
                   {Ref, R} -> R
               after ?SEARCH_TIMEOUT_MS + 1000 ->
                   {error, timeout}
               end || Ref <- Refs],
    lists:flatmap(fun
        ({ok, R}) -> to_embryo_list(R);
        (_)       -> []
    end, Results).

%% @private `em_disco_relay:query/3' returns the raw `result' frame
%% decoded by em_disco_ws — normalise its `data' field to a flat list
%% of embryo maps.
-spec to_embryo_list(term()) -> [map()].
to_embryo_list(#{<<"data">> := L}) when is_list(L) -> L;
to_embryo_list(#{<<"data">> := M}) when is_map(M)  -> [M];
to_embryo_list(_) -> [].

%%====================================================================
%% Tools schema
%%====================================================================

%% @private
%% @doc Return the MCP tool definitions for `search', `list_agents',
%% and `list_capabilities'.
%% @end
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
                  "node, with their names and capabilities.">>,
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

%% @private
-spec result(term(), term()) -> map().
result(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">>      => Id,
      <<"result">>  => Result}.

%% @private
-spec error_response(term(), integer(), binary()) -> map().
error_response(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">>      => Id,
      <<"error">>   => #{
          <<"code">>    => Code,
          <<"message">> => Message
      }}.

%% @private
-spec parse_jsonrpc(binary()) -> {ok, map() | list()} | {error, term()}.
parse_jsonrpc(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, invalid_json} end.

%% @private
-spec caps_from_args(map()) -> [binary()].
caps_from_args(Args) ->
    case maps:get(<<"capabilities">>, Args, []) of
        L when is_list(L) -> [C || C <- L, is_binary(C)];
        _                 -> []
    end.

%%====================================================================
%% SSE helper
%%====================================================================

%% @private
%% @doc Write a single `event: Event\ndata: Data\n\n' frame to the stream.
%% @end
send_sse(Req, Event, Data) ->
    Frame = <<"event: ", Event/binary, "\ndata: ", Data/binary, "\n\n">>,
    cowboy_req:stream_body(Frame, nofin, Req).

%%====================================================================
%% CORS headers
%%====================================================================

%% @private
%% @doc Return CORS headers allowing all origins, GET/POST/OPTIONS
%% methods, and content-type/accept/authorization request headers.
%% @end
cors_headers() ->
    #{<<"access-control-allow-origin">>  => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> =>
          <<"content-type, accept, authorization">>}.
