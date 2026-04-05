%%%-------------------------------------------------------------------
%%% @doc HTTP Handler for the Agent Registry
%%%
%%% Exposes `GET /registry' so that any Queen agent (or external tool)
%%% can discover which agents are currently connected and what
%%% capabilities they offer.
%%%
%%% This endpoint is read-only and stateless — it reflects the live
%%% contents of the `agent_registry' ETS table, which is maintained
%%% by `em_disco_handlers' as agents connect and disconnect.
%%%
%%% === Response format (JSON) ===
%%% ```
%%%   {
%%%     "agents": [
%%%       {
%%%         "name":         "synth_agent",
%%%         "capabilities": ["summarize", "llm", "translate"],
%%%         "connected_at": 1714000000
%%%       },
%%%       ...
%%%     ]
%%%   }
%%% '''
%%%
%%% Returns HTTP 200 with an empty `agents' list when no agents are
%%% connected. Never returns an error under normal operation.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_registry_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Cowboy request entry point.
%%
%% Reads the `agent_registry' ETS table and serialises its contents
%% as a JSON response. The internal `Pid' field is not exposed.
%% @end
%%--------------------------------------------------------------------
init(Req0, State) ->
    {IP, _Port} = cowboy_req:peer(Req0),
    case em_disco_rate:check(IP) of
        {error, rate_limited} ->
            Req = cowboy_req:reply(429,
                #{<<"content-type">> => <<"application/json">>,
                  <<"retry-after">> => <<"1">>},
                json:encode(#{<<"error">> => <<"rate_limited">>}), Req0),
            {ok, Req, State};
        ok ->
            Agents = [
                #{
                    <<"name">>         => Name,
                    <<"capabilities">> => Caps,
                    <<"connected_at">> => ConnectedAt
                }
                || {Name, Caps, ConnectedAt, _Pid} <- ets:tab2list(agent_registry)
            ],
            Body = json:encode(#{<<"agents">> => Agents}),
            Req1 = cowboy_req:reply(200,
                #{<<"content-type">>                 => <<"application/json">>,
                  <<"access-control-allow-origin">>  => <<"*">>},
                Body,
                Req0
            ),
            {ok, Req1, State}
    end.
