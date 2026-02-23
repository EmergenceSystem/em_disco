%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Handler for em_agent Connections
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
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_handlers).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% `name' is set after "register"; `registered' becomes true after
%% "agent_hello". Only fully-registered agents receive queries.
-record(ws_state, {
    name       = undefined :: binary() | undefined,
    registered = false     :: boolean()
}).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #ws_state{}, #{idle_timeout => infinity}}.

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
            io:format("[disco] Agent name received: ~s~n", [Name]),
            Reply = json:encode(#{
                <<"status">> => <<"ok">>,
                <<"action">> => <<"registered">>
            }),
            {reply, {text, Reply}, State#ws_state{name = Name}};

        %% ── Step 2: capability announcement ─────────────────────────
        %%
        %% Must come after "register" so that the name is known.
        %% Inserts {Name, Caps, ConnectedAt, Pid} into agent_registry,
        %% making the agent visible for query dispatch and GET /registry.
        #{<<"action">> := <<"agent_hello">>, <<"capabilities">> := Caps}
          when State#ws_state.name =/= undefined ->
            Name        = State#ws_state.name,
            ConnectedAt = erlang:system_time(second),
            ets:insert(agent_registry, {Name, Caps, ConnectedAt, self()}),
            io:format("[disco] Agent registered: ~s, capabilities: ~p~n", [Name, Caps]),
            Reply = json:encode(#{
                <<"status">>       => <<"ok">>,
                <<"action">>       => <<"agent_registered">>,
                <<"capabilities">> => Caps
            }),
            {reply, {text, Reply}, State#ws_state{registered = true}};

        %% ── agent_hello before register: reject gracefully ───────────
        #{<<"action">> := <<"agent_hello">>} ->
            io:format("[disco] agent_hello received before register — ignoring~n"),
            Reply = json:encode(#{
                <<"error">> => <<"must register before agent_hello">>
            }),
            {reply, {text, Reply}, State};

        %% ── Query result ─────────────────────────────────────────────
        #{<<"action">> := <<"result">>, <<"id">> := Id, <<"data">> := Result} ->
            case ets:lookup(pending_queries, Id) of
                [{Id, CallerPid}] ->
                    io:format("[disco] Forwarding result for query ~s to caller ~p~n",
                              [Id, CallerPid]),
                    CallerPid ! {query_result, Id, Result},
                    ets:delete(pending_queries, Id);
                [] ->
                    io:format("[disco] No pending caller for query ~s (already timed out?)~n",
                              [Id])
            end,
            {ok, State};

        %% ── Unknown frame ────────────────────────────────────────────
        _ ->
            io:format("[disco] Unknown WS message from agent ~p~n",
                      [State#ws_state.name]),
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
    %% Connected but never sent agent_hello — not in agent_registry.
    io:format("[disco] Unregistered agent disconnected: ~s~n", [Name]),
    ok;
terminate(_Reason, _Req, #ws_state{name = Name, registered = true}) ->
    ets:delete(agent_registry, Name),
    io:format("[disco] Agent disconnected: ~s~n", [Name]),
    ok.
