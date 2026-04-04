%%%-------------------------------------------------------------------
%%% @doc
%%% Token Bucket Rate Limiter for em_disco
%%%
%%% Hot path (`check/1`) reads and writes ETS directly — no gen_server
%%% call on the request path. The gen_server only handles periodic
%%% cleanup of stale entries.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_rate).
-behaviour(gen_server).

-export([start_link/0, check/1]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2]).

-define(SWEEP_INTERVAL_MS, 60000).
-define(ENTRY_TTL_MS, 300000).

%%====================================================================
%% Public API
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Start the rate-limiter gen_server under the supervisor.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Check whether the given IP address is within its rate limit.
%%
%% Uses a token-bucket algorithm. Reads and writes `rate_buckets' ETS
%% directly on the hot path — no gen_server call per request.
%%
%% Returns `ok' if the request is allowed, `{error, rate_limited}'
%% otherwise.
%% @end
%%--------------------------------------------------------------------
-spec check(tuple()) -> ok | {error, rate_limited}.
check(IP) ->
    Rate  = rate_for_ip(IP),
    Burst = burst_for_ip(IP),
    Now   = erlang:monotonic_time(millisecond),
    case ets:lookup(rate_buckets, IP) of
        [] ->
            ets:insert(rate_buckets, {IP, Burst - 1.0, Now}),
            ok;
        [{IP, Tokens, LastRefill}] ->
            Elapsed  = (Now - LastRefill) / 1000.0,
            Refilled = min(to_float(Burst), Tokens + Elapsed * Rate),
            case Refilled >= 1.0 of
                true ->
                    ets:insert(rate_buckets, {IP, Refilled - 1.0, Now}),
                    ok;
                false ->
                    ets:insert(rate_buckets, {IP, Refilled, Now}),
                    {error, rate_limited}
            end
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {ok, #{}}.

handle_info(sweep, State) ->
    Cutoff = erlang:monotonic_time(millisecond) - ?ENTRY_TTL_MS,
    ets:select_delete(rate_buckets, [
        {{'_', '_', '$1'}, [{'<', '$1', Cutoff}], [true]}
    ]),
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% @private
-spec rate_for_ip(tuple()) -> number().
rate_for_ip(IP) ->
    case is_localhost(IP) of
        true  -> application:get_env(em_disco, rate_limit_localhost, 1000);
        false -> application:get_env(em_disco, rate_limit_per_second, 10)
    end.

%% @private
-spec burst_for_ip(tuple()) -> number().
burst_for_ip(IP) ->
    case is_localhost(IP) of
        true  -> application:get_env(em_disco, rate_limit_localhost, 1000);
        false -> application:get_env(em_disco, rate_limit_burst, 30)
    end.

%% @private
-spec is_localhost(tuple()) -> boolean().
is_localhost({127, 0, 0, 1})             -> true;
is_localhost({0, 0, 0, 0, 0, 0, 0, 1})  -> true;
is_localhost(_)                          -> false.

%% @private
-spec to_float(number()) -> float().
to_float(N) when is_integer(N) -> N * 1.0;
to_float(N) when is_float(N)   -> N.
