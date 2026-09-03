%%%-------------------------------------------------------------------
%%% @doc em_disco OTP application callback.
%%%
%%% Starts the supervisor, then wires the em_pop gossip node.
%%% em_disco is a pure gossip seed: it maintains a large peer table
%%% for network discovery but serves no HTTP.
%%%
%%% Configuration keys read from the `em_disco' application env:
%%%   gossip_port  (default 9100) — em_pop TCP gossip listener port
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
            ok = start_pop(),
            {ok, Pid};
        Error ->
            Error
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    catch em_pop_sup:stop_node(disco),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Start the em_pop gossip node.
%%
%% Called from start/2 after the supervisor is running.
%% Cleans up any stale state from a previous run first.
%% @end
%%--------------------------------------------------------------------
-spec start_pop() -> ok.
start_pop() ->
    GossipPort = application:get_env(em_disco, gossip_port, 9100),
    Seeds      = application:get_env(em_disco, pop_seeds,   []),
    Vec        = em_filter_vec:from_capabilities([<<"bootstrap">>, <<"registry">>]),

    %% Clean up stale state (supervisor restart scenario).
    catch em_pop_sup:stop_node(disco),

    %% Start em_pop gossip node with a 10 000-peer table.
    {ok, PopPid} = em_pop_sup:start_node(disco, #{
        port            => GossipPort,
        advertise_host  => list_to_binary(os:getenv("EM_POP_ADVERTISE_HOST", "localhost")),
        advertise_port  => list_to_integer(os:getenv("EM_POP_ADVERTISE_PORT", integer_to_list(GossipPort))),
        vector          => Vec,
        role            => hub,
        public_host     => case os:getenv("EM_POP_PUBLIC_HOST") of
                               false -> undefined;
                               ""    -> undefined;
                               PH    -> list_to_binary(PH)
                           end,
        max_peers       => 10_000,
        gossip_interval => 5_000,
        seeds           => Seeds,
        ban_authority_pubkeys => [ base64:decode(B) || B <- application:get_env(em_disco, ban_authority_pubkeys, []) ]
    }),

    %% Contact bootstrap peers (fire-and-forget; errors are harmless).
    lists:foreach(fun({H, P}) ->
        catch em_pop_node:add_peer(PopPid, H, P)
    end, Seeds),

    logger:notice("[em_disco] gossip port ~w", [GossipPort]),
    ok.
