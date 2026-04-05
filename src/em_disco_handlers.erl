%%%-------------------------------------------------------------------
%%% @doc WebSocket Handler for em_agent Connections
%%%
%%% Each agent opens a persistent WebSocket connection to this handler
%%% on startup. The expected handshake is:
%%%
%%%   1. Agent sends `register'   — announces its name.
%%%   2. Agent sends `agent_hello' — announces its capabilities.
%%%      Only after both frames is the agent visible in `agent_registry'
%%%      and therefore eligible to receive queries.
%%%
%%% === Message Protocol (JSON over WebSocket) ===
%%%
%%% Agent → Disco:
%%% ```
%%%   { "action": "register",    "name": "<name>" }
%%%   { "action": "agent_hello", "capabilities": ["cap1", "cap2", ...] }
%%%   { "action": "result",      "id": "<query_id>", "data": <result> }
%%% '''
%%%
%%% Disco → Agent:
%%% ```
%%%   { "status": "ok", "action": "registered" }
%%%   { "status": "ok", "action": "agent_registered", "capabilities": [...] }
%%%   { "action": "query", "id": "<query_id>", "body": "<query_body>" }
%%% '''
%%%
%%% === Internal Erlang Messages ===
%%%
%%% `em_disco:query/1' sends `{send, Payload}' to every registered
%%% handler pid. The handler forwards it to the agent as a WS text frame.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_handlers).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% `name' is set after "register"; `registered' becomes true after
%% "agent_hello". Only fully-registered agents receive queries.
-record(ws_state, {
    name       = undefined :: binary() | undefined,
    registered = false     :: boolean(),
    claims     = #{}       :: map()
}).

%%--------------------------------------------------------------------
%% @doc Cowboy upgrade callback — validates JWT when auth is required.
%%
%% Reads the `?token=...' query parameter and verifies it with
%% `em_disco_auth:verify/1'. Upgrades to WebSocket on success or
%% replies HTTP 401 on failure. When `require_auth' is `false' in
%% application config the token check is skipped.
%% @end
%%--------------------------------------------------------------------
init(Req, _Opts) ->
    RequireAuth = application:get_env(em_disco, require_auth, true),
    QS = cowboy_req:parse_qs(Req),
    Token = proplists:get_value(<<"token">>, QS, undefined),
    case {RequireAuth, em_disco_auth:verify(Token)} of
        {false, _} ->
            Timeout = application:get_env(em_disco, ws_idle_timeout, 60000),
            {cowboy_websocket, Req, #ws_state{claims = #{}}, #{idle_timeout => Timeout}};
        {_, {ok, Claims}} ->
            Timeout = application:get_env(em_disco, ws_idle_timeout, 60000),
            {cowboy_websocket, Req, #ws_state{claims = Claims}, #{idle_timeout => Timeout}};
        {true, {error, Reason}} ->
            logger:warning("WS auth rejected", #{reason => Reason}),
            Req1 = cowboy_req:reply(401,
                #{<<"content-type">> => <<"application/json">>},
                json:encode(#{<<"error">> => <<"unauthorized">>}), Req),
            {ok, Req1, #ws_state{}}
    end.

%%--------------------------------------------------------------------
%% @doc WebSocket initialisation callback — no action required.
%% @end
%%--------------------------------------------------------------------
websocket_init(State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Handles incoming WebSocket frames from the connected agent.
%%
%% Three actions are recognised (in expected order):
%%   `register'    — first frame; stores the agent name in state.
%%   `agent_hello' — second frame; writes the agent into `agent_registry'.
%%   `result'      — carries query results back to the HTTP caller.
%%
%% Any other action returns a JSON error frame without crashing.
%% @end
%%--------------------------------------------------------------------
websocket_handle({text, Data}, State) ->
    case json:decode(Data) of

        %% ── Step 1: name registration ────────────────────────────────
        #{<<"action">> := <<"register">>, <<"name">> := Name} ->
            RequireAuth = application:get_env(em_disco, require_auth, true),
            Sub = maps:get(<<"sub">>, State#ws_state.claims, undefined),
            case RequireAuth =:= false orelse Sub =:= Name of
                true ->
                    logger:debug("Agent name received", #{agent => Name}),
                    Reply = json:encode(#{
                        <<"status">> => <<"ok">>,
                        <<"action">> => <<"registered">>
                    }),
                    {reply, {text, Reply}, State#ws_state{name = Name}};
                false ->
                    logger:warning("Name mismatch", #{name => Name, sub => Sub}),
                    Reply = json:encode(#{
                        <<"status">> => <<"error">>,
                        <<"reason">> => <<"name_mismatch">>
                    }),
                    {reply, {text, Reply}, State}
            end;

        %% ── Step 2: capability announcement ─────────────────────────
        %%
        %% Must come after "register" so that the name is known.
        %% Inserts {Name, Caps, ConnectedAt, Pid} into agent_registry,
        %% making the agent visible for query dispatch and GET /registry.
        #{<<"action">> := <<"agent_hello">>, <<"capabilities">> := Caps}
          when State#ws_state.name =/= undefined ->
            Name = State#ws_state.name,
            case ets:lookup(agent_registry, Name) of
                [{Name, _OldCaps, _OldAt, _OldPid}] ->
                    logger:warning("Duplicate agent name rejected", #{agent => Name}),
                    Reply = json:encode(#{
                        <<"status">> => <<"error">>,
                        <<"reason">> => <<"name_taken">>
                    }),
                    {reply, {text, Reply}, State};
                [] ->
                    ConnectedAt = erlang:system_time(second),
                    ets:insert(agent_registry, {Name, Caps, ConnectedAt, self()}),
                    logger:notice("[em_disco] agent connected: ~ts", [Name]),
                    em_disco_sse_registry:broadcast(),
                    Reply = json:encode(#{
                        <<"status">>       => <<"ok">>,
                        <<"action">>       => <<"agent_registered">>,
                        <<"capabilities">> => Caps
                    }),
                    {reply, {text, Reply}, State#ws_state{registered = true}}
            end;

        %% ── agent_hello before register: reject gracefully ───────────
        #{<<"action">> := <<"agent_hello">>} ->
            logger:warning("agent_hello before register"),
            Reply = json:encode(#{
                <<"error">> => <<"must register before agent_hello">>
            }),
            {reply, {text, Reply}, State};

        %% ── Query result ─────────────────────────────────────────────
        %%
        %% IMPORTANT: do NOT delete the pending_queries entry here.
        %% Multiple agents may respond to the same query id.
        %% collect_results/4 in em_disco owns the cleanup, either when
        %% all expected results arrive or when the timeout fires.
        #{<<"action">> := <<"result">>, <<"id">> := Id, <<"data">> := Result} ->
            case ets:lookup(pending_queries, Id) of
                [{Id, CallerPid}] ->
                    logger:debug("Forwarding result", #{query_id => Id, caller => CallerPid}),
                    CallerPid ! {query_result, Id, Result};
                [] ->
                    logger:debug("No pending caller", #{query_id => Id})
            end,
            {ok, State};

        %% ── Unknown frame ────────────────────────────────────────────
        _ ->
            logger:warning("Unknown WS message", #{agent => State#ws_state.name}),
            Reply = json:encode(#{<<"error">> => <<"unknown_action">>}),
            {reply, {text, Reply}, State}
    end;

websocket_handle(_Frame, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Forwards outbound payloads from `em_disco:query/1' to the agent.
%% @end
%%--------------------------------------------------------------------
websocket_info({send, Data}, State) ->
    {reply, {text, Data}, State};

websocket_info(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Cleans up `agent_registry' when an agent disconnects.
%%
%% If the agent never completed the handshake (name is undefined or
%% `agent_hello' was never received) there is nothing to clean up.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _Req, #ws_state{name = undefined}) ->
    ok;
terminate(_Reason, _Req, #ws_state{name = Name, registered = false}) ->
    logger:warning("Unregistered agent disconnected", #{agent => Name}),
    ok;
terminate(_Reason, _Req, #ws_state{name = Name, registered = true}) ->
    ets:delete(agent_registry, Name),
    logger:notice("[em_disco] agent disconnected: ~ts", [Name]),
    em_disco_sse_registry:broadcast(),
    ok.
