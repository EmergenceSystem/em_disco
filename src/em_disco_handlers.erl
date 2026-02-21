%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Handler for em_filter Connections
%%%
%%% Each `em_filter' instance opens a persistent WebSocket connection
%%% to this handler on startup. The handler is responsible for:
%%%
%%% <ul>
%%%   <li>Registering the filter in the `filter_registry' ETS table.</li>
%%%   <li>Forwarding query payloads sent by `em_disco:query/1'.</li>
%%%   <li>Routing results back to the waiting caller process.</li>
%%%   <li>Cleaning up the registry on disconnect.</li>
%%% </ul>
%%%
%%% === Message Protocol (JSON over WebSocket) ===
%%%
%%% Filter → Disco:
%%% ```
%%%   { "action": "register", "name": "<filter_name>" }
%%%   { "action": "result",   "id": "<query_id>", "data": <r> }
%%% '''
%%%
%%% Disco → Filter:
%%% ```
%%%   { "action": "query",  "id": "<query_id>", "body": "<query_body>" }
%%%   { "status": "ok",     "action": "registered" }
%%% '''
%%%
%%% === Internal Erlang Messages ===
%%%
%%% `em_disco:query/1' sends `{send, Payload}' to every registered
%%% handler pid. The handler forwards it to the filter as a WS text frame.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_handlers).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-record(ws_state, {
    filter_name = undefined :: binary() | undefined
}).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #ws_state{}, #{idle_timeout => infinity}}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Data}, State) ->
    case json:decode(Data) of

        #{<<"action">> := <<"register">>, <<"name">> := Name} ->
            ets:insert(filter_registry, {Name, self()}),
            io:format("[disco] Filter registered: ~s~n", [Name]),
            Reply = json:encode(#{
                <<"status">> => <<"ok">>,
                <<"action">> => <<"registered">>
            }),
            {reply, {text, Reply}, State#ws_state{filter_name = Name}};

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

        _ ->
            io:format("[disco] Unknown WS message from filter ~p~n",
                      [State#ws_state.filter_name]),
            Reply = json:encode(#{<<"error">> => <<"unknown_action">>}),
            {reply, {text, Reply}, State}
    end;

websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({send, Data}, State) ->
    {reply, {text, Data}, State};

websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #ws_state{filter_name = undefined}) ->
    ok;
terminate(_Reason, _Req, #ws_state{filter_name = Name}) ->
    ets:delete(filter_registry, Name),
    io:format("[disco] Filter disconnected: ~s~n", [Name]),
    ok.
