%%%-------------------------------------------------------------------
%%% @doc WebSocket ingress for em_disco (`/ws/filter').
%%%
%%% Model B handshake: the first frame on the socket must be a valid
%%% self-signed `hello' ({name, pubkey, sig, capabilities}). Once
%%% verified, the connecting filter is registered in
%%% `em_disco_registry' (id -> ws pid) and injected into the gossip
%%% node as a relay peer via `em_pop_node:add_relay_peer/2'.
%%%
%%% After the handshake, `result' frames tagged with a query id are
%%% forwarded to `em_disco_relay:deliver/2', and `relay_query'
%%% messages from `em_disco_relay' are pushed to the peer as `query'
%%% frames.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

init(Req, State) ->
    {cowboy_websocket, Req, State, #{idle_timeout => 60_000}}.

websocket_init(State) ->
    {ok, State#{id => undefined}}.

%% First frame must be a valid hello.
websocket_handle({text, Data}, #{id := undefined, node := Node} = S) ->
    case (catch json:decode(Data)) of
        #{<<"action">> := <<"hello">>, <<"pubkey">> := PubB64,
          <<"sig">> := SigB64, <<"name">> := Name} = M ->
            Pub = base64:decode(PubB64),
            Sig = base64:decode(SigB64),
            Id  = em_pop_crypto:id_of(Pub),
            Ok  = em_pop_crypto:verify(
                    em_pop_crypto:canonical_identity(#{id => Id, name => Name}),
                    Sig, Pub),
            case Ok of
                true ->
                    Caps = maps:get(<<"capabilities">>, M, []),
                    ok = em_disco_registry:register(Id, self()),
                    %% Inject a relay peer into the gossip node.
                    em_pop_node:add_relay_peer(Node, #{
                        id => Id, name => Name, pubkey => Pub,
                        capabilities => Caps}),
                    Ack = json:encode(#{<<"action">> => <<"hello_ok">>,
                                        <<"id">> => base64:encode(Id)}),
                    {reply, {text, Ack}, S#{id => Id}};
                false ->
                    Err = json:encode(#{<<"action">> => <<"error">>,
                                        <<"reason">> => <<"bad_selfsig">>}),
                    {reply, {text, Err}, S}
            end;
        _ ->
            Err = json:encode(#{<<"action">> => <<"error">>,
                                <<"reason">> => <<"expected_hello">>}),
            {reply, {text, Err}, S}
    end;
%% After hello: results come back tagged with a query id.
websocket_handle({text, Data}, #{id := Id} = S) when Id =/= undefined ->
    case (catch json:decode(Data)) of
        #{<<"action">> := <<"result">>, <<"id">> := QId} = R ->
            em_disco_relay:deliver(QId, R),
            {ok, S};
        _ -> {ok, S}
    end;
websocket_handle(_Frame, S) -> {ok, S}.

%% A relay request arrives as a message from em_disco_relay.
websocket_info({relay_query, QId, Query}, S) ->
    Frame = json:encode(#{<<"action">> => <<"query">>,
                          <<"id">> => QId, <<"body">> => Query}),
    {reply, {text, Frame}, S};
websocket_info(_I, S) -> {ok, S}.

terminate(_R, _Req, #{id := Id}) when Id =/= undefined ->
    catch em_disco_registry:unregister(Id), ok;
terminate(_R, _Req, _S) -> ok.
