%%%-------------------------------------------------------------------
%%% @doc em_disco OTP application callback.
%%%
%%% Starts the supervisor, then wires the em_pop gossip node and the
%%% Cowboy /agent/query listener. Both are started after the supervisor
%%% is running because they are managed by external processes:
%%%   - em_pop_sup (a child of em_filter_sup) owns the gossip node.
%%%   - Ranch (started by Cowboy) owns the HTTP listener.
%%%
%%% Configuration keys read from the `em_disco' application env:
%%%   gossip_port  (default 9100) — em_pop TCP gossip listener port
%%%   query_port   (default 9101) — /agent/query HTTP listener port
%%%   pop_seeds    (default [])   — [{Host, Port}] bootstrap peers
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_app).
-behaviour(application).
-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case em_disco_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    catch cowboy:stop_listener(em_disco_query_listener),
    catch em_pop_sup:stop_node(disco),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Start the em_pop gossip node and the Cowboy HTTP listener.
%%
%% Called from start/2 after the supervisor is running.
%% Cleans up any stale state from a previous run first.
%% @end
%%--------------------------------------------------------------------
-spec start_pop_and_http() -> ok.
start_pop_and_http() ->
    GossipPort = application:get_env(em_disco, gossip_port, 9100),
    QueryPort  = application:get_env(em_disco, query_port,  9101),
    Seeds      = application:get_env(em_disco, pop_seeds,   []),
    Vec        = em_filter_vec:from_capabilities([<<"bootstrap">>, <<"registry">>]),

    %% Clean up stale state (supervisor restart scenario).
    catch em_pop_sup:stop_node(disco),
    catch cowboy:stop_listener(em_disco_query_listener),

    %% Start em_pop gossip node with a 10 000-peer table.
    {ok, PopPid} = em_pop_sup:start_node(disco, #{
        port            => GossipPort,
        vector          => Vec,
        max_peers       => 10_000,
        gossip_interval => 5_000
    }),

    %% Contact bootstrap peers (fire-and-forget; errors are harmless).
    lists:foreach(fun({H, P}) ->
        catch em_pop_node:add_peer(PopPid, H, P)
    end, Seeds),

    %% Start the direct-query Cowboy listener.
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_disco_query_handler, #{}}]}
    ]),
    {ok, _} = cowboy:start_clear(em_disco_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),

    logger:notice("[em_disco] gossip port ~w  query port ~w",
                  [GossipPort, QueryPort]),
    ok.
