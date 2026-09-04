%%%-------------------------------------------------------------------
%%% @doc em_disco top-level supervisor.
%%%
%%% Owns the WS-filter registry (peer_id -> ws_pid). The em_pop
%%% gossip node and the Cowboy HTTP listener are started by
%%% em_disco_app:start/2 after this supervisor is running, because
%%% they are managed externally (em_pop_sup owns the gossip node;
%%% Ranch owns the listener).
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% Create the WS-ingress rate-limit ETS table now, in the
    %% supervisor process, so it outlives individual connections
    %% (mirrors emquest_ratelimit:init/0 in Emquest's supervisor).
    em_disco_ratelimit:init(),
    {ok, {#{strategy => one_for_one, intensity => 3, period => 10},
          [#{id => em_disco_registry, start => {em_disco_registry, start_link, []}},
           #{id => em_disco_relay, start => {em_disco_relay, start_link, []}}]}}.
