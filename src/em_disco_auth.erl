%%%-------------------------------------------------------------------
%%% @doc JWT authentication for em_disco WebSocket connections.
%%%
%%% Provides HS256 (HMAC-SHA256) token issuance and verification.
%%%
%%% === Token shape ===
%%%
%%%   `sub'  — agent name (must match the `register' frame name)
%%%   `iat'  — issued-at timestamp (Unix seconds)
%%%   `exp'  — expiry timestamp (iat + 86400 s, i.e. 24 hours)
%%%
%%% === Configuration ===
%%%
%%%   `jwt_secret' — application env key; defaults to `<<"changeme">>'.
%%%   <strong>Change this in production.</strong>
%%%
%%% Authentication can be disabled with `{require_auth, false}' in
%%% sys.config — useful for local development.
%%%
%%% Issue a token from the Erlang shell:
%%% ```
%%% Secret = application:get_env(em_disco, jwt_secret, <<"changeme">>),
%%% Token  = em_disco_auth:issue(<<"my_agent">>, Secret).
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_auth).

-export([verify/1, issue/2]).

%%--------------------------------------------------------------------
%% @doc Issues a JWT for the given agent name.
%%
%% The token contains `sub' (agent name), `iat' (issued at), and
%% `exp' (expiration, 24 hours from now).
%% @end
%%--------------------------------------------------------------------
-spec issue(binary(), binary()) -> binary().
issue(AgentName, Secret) ->
    JWK = jose_jwk:from_oct(Secret),
    Now = erlang:system_time(second),
    Claims = #{
        <<"sub">> => AgentName,
        <<"iat">> => Now,
        <<"exp">> => Now + 86400
    },
    Signed = jose_jwt:sign(JWK, #{<<"alg">> => <<"HS256">>}, Claims),
    {_, Token} = jose_jws:compact(Signed),
    Token.

%%--------------------------------------------------------------------
%% @doc Verifies a JWT token against the configured secret.
%%
%% Returns `{ok, Claims}' on success or `{error, Reason}' on failure.
%% Checks: signature validity (HS256 only), expiration.
%% @end
%%--------------------------------------------------------------------
-spec verify(undefined | binary()) -> {ok, map()} | {error, atom()}.
verify(undefined) ->
    {error, missing_token};
verify(<<>>) ->
    {error, empty_token};
verify(Token) when is_binary(Token) ->
    Secret = application:get_env(em_disco, jwt_secret, <<"changeme">>),
    JWK = jose_jwk:from_oct(Secret),
    try
        case jose_jwt:verify_strict(JWK, [<<"HS256">>], Token) of
            {true, JWT, _JWS} ->
                {_, Claims} = jose_jwt:to_map(JWT),
                check_expiry(Claims);
            {false, _JWT, _JWS} ->
                {error, invalid_signature}
        end
    catch
        _:_ -> {error, invalid_token}
    end.

%%====================================================================
%% Internal
%%====================================================================

%% @private
%% @doc Return `{ok, Claims}' if the token's `exp' claim is in the future.
%%
%% Returns `{error, expired}' if the current Unix time is greater than
%% or equal to the `exp' field. A missing `exp' field defaults to `0'
%% and is treated as expired.
%% @end
-spec check_expiry(map()) -> {ok, map()} | {error, expired}.
check_expiry(Claims) ->
    Now = erlang:system_time(second),
    Exp = maps:get(<<"exp">>, Claims, 0),
    case Now < Exp of
        true  -> {ok, Claims};
        false -> {error, expired}
    end.
