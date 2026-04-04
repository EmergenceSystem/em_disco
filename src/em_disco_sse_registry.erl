%%%-------------------------------------------------------------------
%%% @doc
%%% SSE Registry Broadcaster for em_disco
%%%
%%% Tracks browser processes that are holding open a
%%% `GET /registry/events' SSE connection and broadcasts the current
%%% agent list to all of them whenever the `agent_registry' ETS table
%%% changes.
%%%
%%% === API ===
%%%
%%%   `subscribe/0' — called by `em_disco_registry_events_handler' when
%%%                   a browser opens the SSE stream. Registers the
%%%                   calling process as a subscriber.
%%%
%%%   `broadcast/0' — called by `em_disco_handlers' after any change to
%%%                   `agent_registry' (agent connect or disconnect).
%%%                   Reads the current table, encodes it as JSON, and
%%%                   sends `{registry_update, Payload}' to every live
%%%                   subscriber.
%%%
%%% Dead subscribers are detected via process monitors and removed
%%% automatically, so the subscriber list never leaks.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_sse_registry).
-behaviour(gen_server).

-export([start_link/0, subscribe/0, broadcast/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Start the SSE registry broadcaster gen_server.
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register the calling process as an SSE subscriber.
%%
%% Called by `em_disco_registry_events_handler' when a browser opens
%% `GET /registry/events'. The gen_server monitors the caller so that
%% it is automatically removed when the browser disconnects.
%% @end
-spec subscribe() -> ok.
subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}).

%% @doc Push the current agent list to all subscribers.
%%
%% Reads `agent_registry' ETS, encodes it as JSON, and sends
%% `{registry_update, Payload}' to every live subscriber PID.
%% Safe to call when no subscribers are connected.
%% @end
-spec broadcast() -> ok.
broadcast() ->
    gen_server:cast(?MODULE, broadcast).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% State: list of {Pid, MonitorRef} pairs
init([]) ->
    {ok, []}.

handle_call({subscribe, Pid}, _From, Subs) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok, [{Pid, Ref} | Subs]};
handle_call(Req, _From, State) ->
    logger:warning("[em_disco_sse_registry] unexpected call: ~p", [Req]),
    {reply, {error, unknown_call}, State}.

handle_cast(broadcast, Subs) ->
    Payload = build_payload(),
    lists:foreach(fun({Pid, _Ref}) ->
        Pid ! {registry_update, Payload}
    end, Subs),
    {noreply, Subs};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% Remove dead subscribers
handle_info({'DOWN', Ref, process, Pid, _Reason}, Subs) ->
    {noreply, [{P, R} || {P, R} <- Subs, P =/= Pid orelse R =/= Ref]};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

%% @private
%% @doc Encode the current agent_registry ETS contents as a JSON binary.
%% Returns the same shape as GET /registry: `{"agents": [...]}`.
%% @end
-spec build_payload() -> binary().
build_payload() ->
    Agents = [
        #{
            <<"name">>         => Name,
            <<"capabilities">> => Caps,
            <<"connected_at">> => ConnectedAt
        }
        || {Name, Caps, ConnectedAt, _Pid} <- ets:tab2list(agent_registry)
    ],
    iolist_to_binary(json:encode(#{<<"agents">> => Agents})).
