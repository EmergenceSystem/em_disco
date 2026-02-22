%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Handler for em_filter / em_agent Connections
%%%
%%% Each node (filter or agent) opens a persistent WebSocket connection
%%% to this handler on startup. The handler is responsible for:
%%%
%%% <ul>
%%%   <li>Registering the node in `filter_registry' on `register'.</li>
%%%   <li>Optionally registering capabilities in `agent_registry' on
%%%       `agent_hello' (agents only — plain filters never send this).</li>
%%%   <li>Forwarding query payloads sent by `em_disco:query/1'.</li>
%%%   <li>Routing results back to the waiting caller process.</li>
%%%   <li>Cleaning up both registries on disconnect.</li>
%%% </ul>
%%%
%%% === Message Protocol (JSON over WebSocket) ===
%%%
%%% Node → Disco:
%%% ```
%%%   %% All nodes (filters and agents)
%%%   { "action": "register",    "name": "<name>" }
%%%   { "action": "result",      "id": "<query_id>", "data": <result> }
%%%
%%%   %% Agents only — sent after "register", never by plain filters
%%%   { "action": "agent_hello", "capabilities": ["cap1", "cap2", ...] }
%%% '''
%%%
%%% Disco → Node:
%%% ```
%%%   { "action": "query",      "id": "<query_id>", "body": "<query_body>" }
%%%   { "status": "ok",         "action": "registered" }
%%%   { "status": "ok",         "action": "agent_registered",
%%%     "capabilities": [...] }
%%% '''
%%%
%%% === Internal Erlang Messages ===
%%%
%%% `em_disco:query/1' sends `{send, Payload}' to every registered
%%% handler pid. The handler forwards it to the node as a WS text frame.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_handlers).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-record(ws_state, {
    filter_name = undefined :: binary() | undefined,
    is_agent    = false     :: boolean()
}).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #ws_state{}, #{idle_timeout => infinity}}.

websocket_init(State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Handles incoming WebSocket frames from the connected node.
%%
%% Three actions are recognised:
%%   `register'    — mandatory first frame from any node.
%%   `result'      — carries query results back to the HTTP caller.
%%   `agent_hello' — optional, agents only; announces capabilities.
%%
%% Any other action returns a JSON error frame without crashing.
%% @end
%%--------------------------------------------------------------------
websocket_handle({text, Data}, State) ->
    case json:decode(Data) of

        %% ── Registration (all nodes) ─────────────────────────────────
        #{<<"action">> := <<"register">>, <<"name">> := Name} ->
            ets:insert(filter_registry, {Name, self()}),
            io:format("[disco] Node registered: ~s~n", [Name]),
            Reply = json:encode(#{
                <<"status">> => <<"ok">>,
                <<"action">> => <<"registered">>
            }),
            {reply, {text, Reply}, State#ws_state{filter_name = Name}};

        %% ── Query result (all nodes) ─────────────────────────────────
        #{<<"action">> := <<"result">>, <<"id">> := Id, <<"data">> := Result} ->
            case ets:lookup(pending_queries, Id) of
                [{Id, CallerPid}] ->
                    io:format("[disco] Forwarding result to caller ~p~n", [CallerPid]),
                    CallerPid ! {query_result, Id, Result},
                    ets:delete(pending_queries, Id);
                [] ->
                    io:format("[disco] No pending caller for query ~s (already timed out?)~n", [Id])
            end,
            {ok, State};

        %% ── Agent hello (agents only) ────────────────────────────────
        %%
        %% Must be sent AFTER "register" so that filter_name is known.
        %% Capabilities is a list of binary strings describing what the
        %% agent can do (e.g. ["summarize", "llm", "translate"]).
        %% The Queen queries GET /registry to discover these at runtime.
        #{<<"action">> := <<"agent_hello">>, <<"capabilities">> := Caps}
          when State#ws_state.filter_name =/= undefined ->
            Name        = State#ws_state.filter_name,
            ConnectedAt = erlang:system_time(second),
            ets:insert(agent_registry, {Name, Caps, ConnectedAt}),
            io:format("[disco] Agent hello from ~s, capabilities: ~p~n", [Name, Caps]),
            Reply = json:encode(#{
                <<"status">>       => <<"ok">>,
                <<"action">>       => <<"agent_registered">>,
                <<"capabilities">> => Caps
            }),
            {reply, {text, Reply}, State#ws_state{is_agent = true}};

        %% ── agent_hello before register: reject gracefully ───────────
        #{<<"action">> := <<"agent_hello">>} ->
            io:format("[disco] agent_hello received before register — ignoring~n"),
            Reply = json:encode(#{
                <<"error">> => <<"must register before agent_hello">>
            }),
            {reply, {text, Reply}, State};

        %% ── Unknown frame ────────────────────────────────────────────
        _ ->
            io:format("[disco] Unknown WS message from node ~p~n",
                      [State#ws_state.filter_name]),
            Reply = json:encode(#{<<"error">> => <<"unknown_action">>}),
            {reply, {text, Reply}, State}
    end;

websocket_handle(_Frame, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Forwards outbound payloads from `em_disco:query/1' to the node.
%% @end
%%--------------------------------------------------------------------
websocket_info({send, Data}, State) ->
    {reply, {text, Data}, State};

websocket_info(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Cleans up both registries when a node disconnects.
%%
%% Plain filters only appear in `filter_registry'.
%% Agents appear in both; both entries are removed.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _Req, #ws_state{filter_name = undefined}) ->
    ok;
terminate(_Reason, _Req, #ws_state{filter_name = Name, is_agent = IsAgent}) ->
    ets:delete(filter_registry, Name),
    case IsAgent of
        true  ->
            ets:delete(agent_registry, Name),
            io:format("[disco] Agent disconnected: ~s~n", [Name]);
        false ->
            io:format("[disco] Filter disconnected: ~s~n", [Name])
    end,
    ok.
