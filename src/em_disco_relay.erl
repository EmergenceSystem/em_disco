%%%-------------------------------------------------------------------
%%% @doc em_disco relay — correlates HTTP `/relay/query` requests to
%%% the WS-filter connection that must answer them.
%%%
%%% Two roles in one module:
%%%   1. A gen_server that tracks in-flight query ids -> waiting
%%%      caller pids (`query/3` / `deliver/2`).
%%%   2. A Cowboy HTTP handler (`init/2`) for
%%%      `POST /relay/query {"peer_id": <base64>, "query": <term>}`.
%%%
%%% Flow: the handler looks up the peer's WS pid via
%%% `em_disco_registry`, pushes `{relay_query, QId, Query}` to it, and
%%% awaits `{relay_result, QId, R}` for up to `TimeoutMs`. The WS
%%% handler (em_disco_ws, Task 1.3) calls `deliver/2` when a result
%%% frame arrives from the filter.
%%%
%%% Abuse control: at most `?MAX_INFLIGHT_PER_PEER` queries may be
%%% in flight for a given peer at once; a query issued while a peer is
%%% already at that cap is refused with `{error, too_many_inflight}'
%%% (surfaced as HTTP 429) instead of being queued.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_relay).
-behaviour(gen_server).

%% cowboy handler
-export([init/2]).
%% api
-export([start_link/0, query/3, deliver/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAX_INFLIGHT_PER_PEER, 8).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Synchronous: push a query into the peer's WS and await its result.
-spec query(term(), term(), non_neg_integer()) ->
    {ok, term()} | {error, not_found | timeout | too_many_inflight}.
query(PeerId, Query, TimeoutMs) ->
    case em_disco_registry:lookup(PeerId) of
        {ok, WsPid} ->
            case gen_server:call(?MODULE, {await, PeerId, self()}) of
                {ok, QId} ->
                    WsPid ! {relay_query, QId, Query},
                    receive
                        {relay_result, QId, R} -> {ok, R}
                    after TimeoutMs ->
                        gen_server:cast(?MODULE, {cancel, QId}),
                        {error, timeout}
                    end;
                {error, too_many_inflight} ->
                    {error, too_many_inflight}
            end;
        error -> {error, not_found}
    end.

%% @doc Called by em_disco_ws when a result frame arrives.
-spec deliver(term(), term()) -> ok.
deliver(QId, Result) -> gen_server:cast(?MODULE, {deliver, QId, Result}).

init([]) -> {ok, #{waiters => #{}, inflight => #{}}}.

%% @private Register a new in-flight query for PeerId, refusing when
%% the peer is already at the concurrency cap. Waiters map QId to
%% {CallerPid, PeerId} so deliver/cancel can decrement the right
%% peer's counter.
handle_call({await, PeerId, Pid}, _F, #{waiters := W, inflight := I} = S) ->
    Count = maps:get(PeerId, I, 0),
    case Count >= ?MAX_INFLIGHT_PER_PEER of
        true ->
            {reply, {error, too_many_inflight}, S};
        false ->
            QId = base64:encode(crypto:strong_rand_bytes(9)),
            {reply, {ok, QId},
             S#{waiters => W#{QId => {Pid, PeerId}},
                inflight => I#{PeerId => Count + 1}}}
    end;
handle_call(_R, _F, S) -> {reply, ok, S}.

handle_cast({deliver, QId, R}, #{waiters := W, inflight := I} = S) ->
    case maps:take(QId, W) of
        {{Pid, PeerId}, W2} ->
            Pid ! {relay_result, QId, R},
            {noreply, S#{waiters => W2, inflight => decr_inflight(PeerId, I)}};
        error -> {noreply, S}
    end;
handle_cast({cancel, QId}, #{waiters := W, inflight := I} = S) ->
    case maps:take(QId, W) of
        {{_Pid, PeerId}, W2} ->
            {noreply, S#{waiters => W2, inflight => decr_inflight(PeerId, I)}};
        error ->
            {noreply, S}
    end;
handle_cast(_M, S) -> {noreply, S}.

handle_info(_I, S) -> {noreply, S}.

%% @private
-spec decr_inflight(term(), map()) -> map().
decr_inflight(PeerId, I) ->
    case maps:get(PeerId, I, 0) - 1 of
        N when N =< 0 -> maps:remove(PeerId, I);
        N -> I#{PeerId => N}
    end.

%%--------------------------------------------------------------------
%% Cowboy HTTP handler: POST /relay/query {"peer_id":.., "query":..}
%%--------------------------------------------------------------------
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case (catch json:decode(Body)) of
        #{<<"peer_id">> := PeerIdB64, <<"query">> := Q} ->
            PeerId = base64:decode(PeerIdB64),
            case query(PeerId, Q, 5000) of
                {ok, R} ->
                    reply_json(200, R, Req1, State);
                {error, not_found} ->
                    reply_json(404, #{<<"error">> => <<"unknown_peer">>}, Req1, State);
                {error, timeout} ->
                    reply_json(504, #{<<"error">> => <<"relay_timeout">>}, Req1, State);
                {error, too_many_inflight} ->
                    reply_json(429, #{<<"error">> => <<"too_many_inflight">>}, Req1, State)
            end;
        _ ->
            reply_json(400, #{<<"error">> => <<"bad_request">>}, Req1, State)
    end.

%% @private
-spec reply_json(non_neg_integer(), map(), cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
reply_json(Code, Map, Req, State) ->
    R = cowboy_req:reply(Code,
          #{<<"content-type">> => <<"application/json">>},
          iolist_to_binary(json:encode(Map)), Req),
    {ok, R, State}.
