%%%-------------------------------------------------------------------
%%% @doc
%%% HTTP Handler for the Agent Registry
%%%
%%% Exposes `GET /registry' so that any Queen agent (or external tool)
%%% can discover which agents are currently connected and what
%%% capabilities they offer.
%%%
%%% This endpoint is read-only and stateless — it reflects the live
%%% contents of the `agent_registry' ETS table, which is maintained
%%% by `em_disco_handlers' as agents connect and disconnect.
%%%
%%% Plain filters (nodes that never sent `agent_hello') do not appear
%%% here. Use `em_disco:list_filters/0' to enumerate all connected
%%% nodes including plain filters.
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
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_registry_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Cowboy request entry point.
%%
%% Reads the `agent_registry' ETS table and serialises its contents
%% as a JSON response. No request body is consumed.
%% @end
%%--------------------------------------------------------------------
init(Req0, State) ->
    Agents = [
        #{
            <<"name">>         => Name,
            <<"capabilities">> => Caps,
            <<"connected_at">> => ConnectedAt
        }
        || {Name, Caps, ConnectedAt} <- ets:tab2list(agent_registry)
    ],
    Body = json:encode(#{<<"agents">> => Agents}),
    Req1 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req0
    ),
    {ok, Req1, State}.
