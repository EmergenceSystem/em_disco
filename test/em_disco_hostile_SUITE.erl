%%%-------------------------------------------------------------------
%%% @doc
%%% Hostile-node Common Test suite for the em_disco gossip hub.
%%%
%%% Stands up an ENFORCED gossip ingress -- the same `em_pop_http' route
%%% that `em_disco_app:start_http/0' mounts at `/pop/gossip', with the same
%%% option shape (`rate_limit', `rate_key_prefix', `max_body', `max_peers')
%%% and `require_signed_gossip = true' -- in front of a REAL em_pop node
%%% (kvex NIF included), then drives it over real HTTP (httpc) and proves
%%% that adversary gossip requests are blocked while one honestly signed
%%% request is accepted.
%%%
%%% Isolation: ephemeral listener ports, node key/state under the CT
%%% priv_dir, application env restored in end_per_suite.
%%%
%%% Rate limiting is keyed on `cf-connecting-ip' when present (see
%%% em_pop_http:client_key/1), so every case uses its own synthetic client
%%% address and the cases do not share a token bucket.  Only the flood case
%%% that proves the real socket peer is bucketed omits the header.
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_hostile_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([valid_signed_gossip_accepted/1,
         unsigned_rejected/1,
         bearer_rejected_under_enforcement/1,
         forged_sig_rejected/1,
         id_mismatch_rejected/1,
         stale_ts_rejected/1,
         future_ts_rejected/1,
         tampered_body_rejected/1,
         selfsig_name_tamper_rejected/1,
         flood_rate_limited/1,
         rate_limit_keyed_per_source/1,
         oversized_body_rejected/1,
         too_many_peers_rejected/1,
         authz_decision_matrix/1]).

%% Mirrors the em_disco_app route options, with smaller caps so the cases
%% stay fast.
-define(RATE_CAP, 5).
-define(RATE_WINDOW, 60).
-define(MAX_BODY, 8192).
-define(MAX_PEERS, 3).
-define(TOKEN, <<"hostile-suite-shared-bearer">>).
-define(LISTENER, em_disco_hostile_http).

all() ->
    [valid_signed_gossip_accepted,
     unsigned_rejected,
     bearer_rejected_under_enforcement,
     forged_sig_rejected,
     id_mismatch_rejected,
     stale_ts_rejected,
     future_ts_rejected,
     tampered_body_rejected,
     selfsig_name_tamper_rejected,
     flood_rate_limited,
     rate_limit_keyed_per_source,
     oversized_body_rejected,
     too_many_peers_rejected,
     authz_decision_matrix].

%%--------------------------------------------------------------------
%% Suite setup / teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(kvex),
    {ok, _} = application:ensure_all_started(crypto),

    %% Enforcement + a bearer token that must NOT be honoured.
    Saved = [{K, application:get_env(em_filter, K)}
             || K <- [require_signed_gossip, auth_token]],
    application:set_env(em_filter, require_signed_gossip, true),
    application:set_env(em_filter, auth_token, ?TOKEN),

    %% The ETS table must outlive the (short-lived) init_per_suite process.
    Holder = spawn(fun() ->
                       em_disco_ratelimit:init(),
                       receive stop -> ok end
                   end),
    wait_for_table(50),

    %% Real em_pop node (own gossip listener on an ephemeral port).
    NodePort = free_port(),
    NodeDir = filename:join(PrivDir, "node"),
    ok = filelib:ensure_dir(filename:join(NodeDir, "x")),
    Vec = em_filter_vec:from_capabilities([<<"bootstrap">>, <<"registry">>]),
    {ok, NodePid} = em_pop_node:start_link(#{
        name            => <<"hostile-hub">>,
        port            => NodePort,
        vector          => Vec,
        role            => hub,
        persist_dir     => NodeDir,
        gossip_interval => 3600000,
        max_peers       => 100}),
    unlink(NodePid),

    %% Enforced ingress, same shape as em_disco_app:start_http/0.
    Dispatch = cowboy_router:compile([{'_', [
        {"/pop/gossip", em_pop_http,
         #{node => NodePid,
           rate_limit => {em_disco_ratelimit, allow, ?RATE_CAP, ?RATE_WINDOW},
           rate_key_prefix => <<"gossip:">>,
           max_body => ?MAX_BODY,
           max_peers => ?MAX_PEERS}}]}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(?LISTENER),

    {Pub, Priv} = em_pop_crypto:keypair(),
    [{saved_env, Saved}, {holder, Holder}, {node_pid, NodePid},
     {url, "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/pop/gossip"},
     {vec, Vec}, {pub, Pub}, {priv, Priv} | Config].

end_per_suite(Config) ->
    catch cowboy:stop_listener(?LISTENER),
    NodePid = ?config(node_pid, Config),
    catch gen_server:stop(NodePid),
    (?config(holder, Config)) ! stop,
    lists:foreach(
      fun({K, {ok, V}}) -> application:set_env(em_filter, K, V);
         ({K, undefined}) -> application:unset_env(em_filter, K)
      end, ?config(saved_env, Config)),
    ok.

%%--------------------------------------------------------------------
%% Positive control
%%--------------------------------------------------------------------

%% A request carrying the sender's own selfsig and a fresh, matching
%% x-pop-id / x-pop-ts / x-pop-sig is accepted and reaches handle_gossip.
valid_signed_gossip_accepted(Config) ->
    Ident = ident(Config, <<"honest-sender">>),
    {Body, Hdrs} = signed_request(Ident, payload(Ident, Config)),
    {200, RespBody} = post(Config, "10.0.0.1", Hdrs, Body),
    #{<<"id">> := _} = json:decode(RespBody),
    true = peer_known(Config, Ident),
    ok.

%%--------------------------------------------------------------------
%% C-series: authentication
%%--------------------------------------------------------------------

%% C1: no x-pop-* headers and no bearer.
unsigned_rejected(Config) ->
    Ident = ident(Config, <<"unsigned-attacker">>),
    Body = encode(payload(Ident, Config)),
    {401, <<"unauthorized">>} = post(Config, "10.0.0.2", [], Body),
    false = peer_known(Config, Ident),
    ok.

%% The shared bearer is the legacy path: under require_signed_gossip it
%% must NOT be accepted, even when it is the exact configured token.
bearer_rejected_under_enforcement(Config) ->
    Ident = ident(Config, <<"bearer-attacker">>),
    Body = encode(payload(Ident, Config)),
    Right = [{"authorization", "Bearer " ++ binary_to_list(?TOKEN)}],
    Wrong = [{"authorization", "Bearer nope"}],
    {401, _} = post(Config, "10.0.0.3", Right, Body),
    {401, _} = post(Config, "10.0.0.3", Wrong, Body),
    false = peer_known(Config, Ident),
    ok.

%% C2: x-pop-* present but the signature is not the sender's.
forged_sig_rejected(Config) ->
    Ident = ident(Config, <<"forger">>),
    Payload = payload(Ident, Config),
    Body = encode(Payload),
    Ts = now_ms(),
    {_OtherPub, OtherPriv} = em_pop_crypto:keypair(),
    Forged = em_pop_crypto:sign(
               em_pop_crypto:canonical_gossip_auth(
                 maps:get(id, Ident), Ts, crypto:hash(sha256, Body)), OtherPriv),
    {401, _} = post(Config, "10.0.0.4", auth_headers(maps:get(id, Ident), Ts, Forged), Body),
    %% Garbage (non-signature) bytes and a truncated sig, too.
    {401, _} = post(Config, "10.0.0.4",
                    auth_headers(maps:get(id, Ident), Ts, <<"garbage">>), Body),
    {401, _} = post(Config, "10.0.0.4",
                    [{"x-pop-id", binary_to_list(base64:encode(maps:get(id, Ident)))},
                     {"x-pop-ts", integer_to_list(Ts)},
                     {"x-pop-sig", "!!not-base64!!"}], Body),
    false = peer_known(Config, Ident),
    ok.

%% C3: x-pop-id does not match id_of(body pubkey) -- an attacker trying to
%% speak as another node's id with their own key.
id_mismatch_rejected(Config) ->
    Attacker = ident(Config, <<"impersonator">>),
    Victim = ident(Config, <<"victim">>),
    Body = encode(payload(Attacker, Config)),
    Ts = now_ms(),
    %% Attacker signs the auth envelope claiming the victim's id.
    VictimId = maps:get(id, Victim),
    Sig = em_pop_crypto:sign(
            em_pop_crypto:canonical_gossip_auth(VictimId, Ts, crypto:hash(sha256, Body)),
            maps:get(priv, Attacker)),
    {401, _} = post(Config, "10.0.0.5", auth_headers(VictimId, Ts, Sig), Body),
    %% Body that advertises the victim's pubkey but is signed by the attacker.
    VictimPayload = payload(Victim, Config),
    Body2 = encode(VictimPayload),
    Sig2 = em_pop_crypto:sign(
             em_pop_crypto:canonical_gossip_auth(VictimId, Ts, crypto:hash(sha256, Body2)),
             maps:get(priv, Attacker)),
    {401, _} = post(Config, "10.0.0.5", auth_headers(VictimId, Ts, Sig2), Body2),
    false = peer_known(Config, Attacker),
    false = peer_known(Config, Victim),
    ok.

%% C4: validly signed, but the timestamp is far in the past (replay).
stale_ts_rejected(Config) ->
    Ident = ident(Config, <<"replayer">>),
    Body = encode(payload(Ident, Config)),
    OldTs = now_ms() - 10 * 60 * 1000,
    {401, _} = post(Config, "10.0.0.6", signed_headers(Ident, OldTs, Body), Body),
    false = peer_known(Config, Ident),
    ok.

%% C4b: validly signed but timestamped beyond the allowed clock skew.
future_ts_rejected(Config) ->
    Ident = ident(Config, <<"timetraveler">>),
    Body = encode(payload(Ident, Config)),
    FutureTs = now_ms() + 10 * 60 * 1000,
    {401, _} = post(Config, "10.0.0.7", signed_headers(Ident, FutureTs, Body), Body),
    false = peer_known(Config, Ident),
    ok.

%% C5: a captured valid (headers, body) pair cannot be reused with a
%% different body -- the signature is bound to sha256(body).
tampered_body_rejected(Config) ->
    Ident = ident(Config, <<"mitm-victim">>),
    {_Body, Hdrs} = signed_request(Ident, payload(Ident, Config)),
    Tampered = encode((payload(Ident, Config))#{<<"port">> => 6666}),
    {401, _} = post(Config, "10.0.0.8", Hdrs, Tampered),
    ok.

%% C6: the selfsig binds id+name; swapping the name after signing the
%% identity must fail even with a valid transport signature.
selfsig_name_tamper_rejected(Config) ->
    Ident = ident(Config, <<"honest-name">>),
    Payload = (payload(Ident, Config))#{<<"name">> => <<"evil-name">>},
    Body = encode(Payload),
    {401, _} = post(Config, "10.0.0.9",
                    signed_headers(Ident, now_ms(), Body), Body),
    false = peer_known(Config, Ident),
    ok.

%%--------------------------------------------------------------------
%% D-series: resource exhaustion
%%--------------------------------------------------------------------

%% D1: exceeding the per-source token bucket yields 429.  Uses the real
%% socket peer (no cf-connecting-ip) so the bucket is "gossip:127.0.0.1".
flood_rate_limited(Config) ->
    Body = encode(#{}),
    Codes = [element(1, post_raw(Config, [], Body)) || _ <- lists:seq(1, ?RATE_CAP + 3)],
    {Allowed, Limited} = lists:split(?RATE_CAP, Codes),
    %% Within the cap the (unsigned) requests get past the limiter and fail authz...
    true = lists:all(fun(C) -> C =:= 401 end, Allowed),
    %% ...and beyond it they are cut off before authz even runs.
    true = lists:all(fun(C) -> C =:= 429 end, Limited),
    ok.

%% D1b: buckets are per source: exhausting one does not starve another.
rate_limit_keyed_per_source(Config) ->
    Body = encode(#{}),
    Flood = [element(1, post(Config, "10.1.0.1", [], Body))
             || _ <- lists:seq(1, ?RATE_CAP + 2)],
    429 = lists:last(Flood),
    {401, _} = post(Config, "10.1.0.2", [], Body),
    ok.

%% D2: a body over max_body is rejected with 413 -- even when it carries a
%% perfectly valid signature, and before any JSON/crypto work.
oversized_body_rejected(Config) ->
    Ident = ident(Config, <<"fat-sender">>),
    Pad = binary:copy(<<"A">>, ?MAX_BODY * 2),
    Payload = (payload(Ident, Config))#{<<"pad">> => Pad},
    {Body, Hdrs} = signed_request(Ident, Payload),
    true = byte_size(Body) > ?MAX_BODY,
    {413, <<"payload_too_large">>} = post(Config, "10.0.0.10", Hdrs, Body),
    false = peer_known(Config, Ident),
    %% Control: the same identity within the cap is accepted.
    {Body2, Hdrs2} = signed_request(Ident, payload(Ident, Config)),
    true = byte_size(Body2) =< ?MAX_BODY,
    {200, _} = post(Config, "10.0.0.11", Hdrs2, Body2),
    ok.

%% D3: a validly signed payload embedding more than max_peers peers is
%% rejected with 413 and never reaches the peer table.
too_many_peers_rejected(Config) ->
    Ident = ident(Config, <<"peer-stuffer">>),
    Stuffed = [filler_peer(N, Config) || N <- lists:seq(1, ?MAX_PEERS + 1)],
    Payload = (payload(Ident, Config))#{<<"peers">> => Stuffed},
    {Body, Hdrs} = signed_request(Ident, Payload),
    true = byte_size(Body) =< ?MAX_BODY,
    {413, <<"too_many_peers">>} = post(Config, "10.0.0.12", Hdrs, Body),
    false = peer_known(Config, Ident),
    lists:foreach(fun(P) ->
        false = peer_known_id(Config, base64:decode(maps:get(<<"id">>, P)))
    end, Stuffed),
    %% Control: exactly max_peers is within the cap.
    Ok = [filler_peer(N, Config) || N <- lists:seq(1, ?MAX_PEERS)],
    {Body2, Hdrs2} = signed_request(Ident, (payload(Ident, Config))#{<<"peers">> => Ok}),
    {200, _} = post(Config, "10.0.0.13", Hdrs2, Body2),
    ok.

%%--------------------------------------------------------------------
%% Direct function assertions (the pure decision core)
%%--------------------------------------------------------------------

authz_decision_matrix(Config) ->
    Ident = ident(Config, <<"matrix-sender">>),
    Body = encode(payload(Ident, Config)),
    Ts = now_ms(),
    Id = maps:get(id, Ident),
    Sig = em_pop_crypto:sign(
            em_pop_crypto:canonical_gossip_auth(Id, Ts, crypto:hash(sha256, Body)),
            maps:get(priv, Ident)),
    Good = {base64:encode(Id), integer_to_binary(Ts), base64:encode(Sig)},
    None = {undefined, undefined, undefined},
    Bearer = <<"Bearer ", ?TOKEN/binary>>,
    %% valid signature passes in both modes
    ok = em_pop_http:authz_decision(Good, Body, ?TOKEN, undefined, true),
    ok = em_pop_http:authz_decision(Good, Body, ?TOKEN, undefined, false),
    %% enforced: bearer and no-auth are refused
    unauthorized = em_pop_http:authz_decision(None, Body, ?TOKEN, Bearer, true),
    unauthorized = em_pop_http:authz_decision(None, Body, undefined, undefined, true),
    %% fail-closed on partial header triples
    unauthorized = em_pop_http:authz_decision(
                     {base64:encode(Id), undefined, undefined}, Body, ?TOKEN, Bearer, true),
    %% legacy (non-enforced) mode would have admitted the bearer -- this is
    %% exactly the downgrade that require_signed_gossip closes
    ok = em_pop_http:authz_decision(None, Body, ?TOKEN, Bearer, false),
    unauthorized = em_pop_http:authz_decision(None, Body, ?TOKEN, <<"Bearer x">>, false),
    %% peer cap helper
    true  = em_pop_http:peers_within_cap(#{<<"peers">> => [1, 2, 3]}, 3),
    false = em_pop_http:peers_within_cap(#{<<"peers">> => [1, 2, 3, 4]}, 3),
    true  = em_pop_http:peers_within_cap(#{<<"peers">> => [1, 2, 3, 4]}, infinity),
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% A fresh honest identity (keypair + id + name + selfsig).
ident(_Config, Name) ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Id = em_pop_crypto:id_of(Pub),
    SelfSig = em_pop_crypto:sign(
                em_pop_crypto:canonical_identity(#{id => Id, name => Name}), Priv),
    #{pub => Pub, priv => Priv, id => Id, name => Name, selfsig => SelfSig}.

%% The gossip payload a node would POST: its own descriptor + selfsig.
payload(#{pub := Pub, id := Id, name := Name, selfsig := SelfSig}, Config) ->
    #{<<"id">>     => base64:encode(Id),
      <<"name">>   => Name,
      <<"host">>   => <<"127.0.0.1">>,
      <<"port">>   => 9999,
      <<"vector">> => base64:encode(?config(vec, Config)),
      <<"role">>   => <<"leaf">>,
      <<"pubkey">> => base64:encode(Pub),
      <<"sig">>    => base64:encode(SelfSig),
      <<"peers">>  => []}.

%% A minimal peer entry (only counted by the cap check, never merged when
%% the request is rejected).
filler_peer(N, Config) ->
    Id = crypto:hash(md5, integer_to_binary(N)),
    #{<<"id">>     => base64:encode(Id),
      <<"host">>   => <<"127.0.0.1">>,
      <<"port">>   => 20000 + N,
      <<"vector">> => base64:encode(?config(vec, Config))}.

encode(Payload) -> iolist_to_binary(json:encode(Payload)).

now_ms() -> erlang:system_time(millisecond).

%% Encode the payload and sign it with a fresh timestamp.
signed_request(Ident, Payload) ->
    Body = encode(Payload),
    {Body, signed_headers(Ident, now_ms(), Body)}.

signed_headers(#{id := Id, priv := Priv}, Ts, Body) ->
    Sig = em_pop_crypto:sign(
            em_pop_crypto:canonical_gossip_auth(Id, Ts, crypto:hash(sha256, Body)), Priv),
    auth_headers(Id, Ts, Sig).

auth_headers(Id, Ts, Sig) ->
    [{"x-pop-id",  binary_to_list(base64:encode(Id))},
     {"x-pop-ts",  integer_to_list(Ts)},
     {"x-pop-sig", binary_to_list(base64:encode(Sig))}].

%% POST as the synthetic client address Ip (rate-limit bucket key).
post(Config, Ip, Headers, Body) ->
    post_raw(Config, [{"cf-connecting-ip", Ip} | Headers], Body).

post_raw(Config, Headers, Body) ->
    Url = ?config(url, Config),
    {ok, {{_, Status, _}, _RespHdrs, RespBody}} =
        httpc:request(post, {Url, Headers, "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    {Status, RespBody}.

peer_known(Config, #{id := Id}) -> peer_known_id(Config, Id).

peer_known_id(Config, Id) ->
    Peers = em_pop_node:get_peers(?config(node_pid, Config)),
    lists:any(fun(#{id := PId}) -> PId =:= Id end, Peers).

free_port() ->
    {ok, S} = gen_tcp:listen(0, []),
    {ok, P} = inet:port(S),
    gen_tcp:close(S),
    P.

wait_for_table(0) -> error(ratelimit_table_missing);
wait_for_table(N) ->
    case ets:info(em_disco_ratelimit) of
        undefined -> timer:sleep(20), wait_for_table(N - 1);
        _ -> ok
    end.
