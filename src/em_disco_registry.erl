%%%-------------------------------------------------------------------
%%% @doc em_disco WS-filter registry.
%%%
%%% gen_server owning an ETS table mapping peer_id -> ws_pid, for the
%%% live WebSocket connections handled by third-party filters. A later
%%% HTTP /relay/query request looks up the peer_id here to find the
%%% socket process to forward the query through.
%%%
%%% Entries are cleaned up automatically when the registered process
%%% exits, via a process monitor set at registration time.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_registry).
-behaviour(gen_server).

-export([start_link/0, register/2, unregister/1, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, em_disco_ws_registry).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(term(), pid()) -> ok.
register(Id, Pid) -> gen_server:call(?MODULE, {register, Id, Pid}).

-spec unregister(term()) -> ok.
unregister(Id)    -> gen_server:call(?MODULE, {unregister, Id}).

-spec lookup(term()) -> {ok, pid()} | error.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
        [{Id, Pid}] -> {ok, Pid};
        []          -> error
    end.

init([]) ->
    ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #{mons => #{}}}.

handle_call({register, Id, Pid}, _F, #{mons := Mons} = S) ->
    ets:insert(?TAB, {Id, Pid}),
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
