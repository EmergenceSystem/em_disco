%%%-------------------------------------------------------------------
%%% @doc em_disco WS-filter registry.
%%%
%%% gen_server owning an ETS table mapping peer_id -> {ws_pid, Info},
%%% for the live WebSocket connections handled by third-party filters.
%%% A later HTTP /relay/query request looks up the peer_id here to
%%% find the socket process to forward the query through. `Info' is a
%%% map of `#{name => binary(), capabilities => [binary()]}' announced
%%% by the filter at hello time — kept alongside the pid so the MCP
%%% handler can list connected agents/capabilities without a gossip
%%% round-trip (em_pop only keeps a capability *vector*, not the
%%% original capability strings).
%%%
%%% Entries are cleaned up automatically when the registered process
%%% exits, via a process monitor set at registration time.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_registry).
-behaviour(gen_server).

-export([start_link/0, register/3, unregister/1, lookup/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, em_disco_ws_registry).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(term(), pid(), map()) -> ok.
register(Id, Pid, Info) -> gen_server:call(?MODULE, {register, Id, Pid, Info}).

-spec unregister(term()) -> ok.
unregister(Id)    -> gen_server:call(?MODULE, {unregister, Id}).

-spec lookup(term()) -> {ok, pid()} | error.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
        [{Id, Pid, _Info}] -> {ok, Pid};
        []                 -> error
    end.

%% @doc Return `{PeerId, Info}' for every currently registered peer.
-spec list() -> [{term(), map()}].
list() ->
    [{Id, Info} || {Id, _Pid, Info} <- ets:tab2list(?TAB)].

init([]) ->
    ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #{mons => #{}}}.

handle_call({register, Id, Pid, Info}, _F, #{mons := Mons} = S) ->
    ets:insert(?TAB, {Id, Pid, Info}),
    Ref = erlang:monitor(process, Pid),
    {reply, ok, S#{mons => Mons#{Ref => Id}}};
handle_call({unregister, Id}, _F, S) ->
    ets:delete(?TAB, Id),
    {reply, ok, S};
handle_call(_R, _F, S) -> {reply, ok, S}.

handle_cast(_M, S) -> {noreply, S}.

handle_info({'DOWN', Ref, process, _Pid, _R}, #{mons := Mons} = S) ->
    case maps:take(Ref, Mons) of
        {Id, M2} -> ets:delete(?TAB, Id), {noreply, S#{mons => M2}};
        error    -> {noreply, S}
    end;
handle_info(_I, S) -> {noreply, S}.
