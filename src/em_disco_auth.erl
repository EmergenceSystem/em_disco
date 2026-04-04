%%%-------------------------------------------------------------------
%%% @doc
%%% JWT Authentication for em_disco
%%%
%%% Provides token issuance and verification using HS256 (HMAC-SHA256).
%%% The shared secret is read from application config `jwt_secret`.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_disco_auth).

-export([verify/1, issue/2]).

%%--------------------------------------------------------------------
%% @doc Issues a JWT for the given agent name.
%%
%% The token contains `sub` (agent name), `iat` (issued at), and
%% `exp` (expiration, 24 hours from now).
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
%% Returns `{ok, Claims}` on success or `{error, Reason}` on failure.
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
-spec check_expiry(map()) -> {ok, map()} | {error, expired}.
check_expiry(Claims) ->
    Now = erlang:system_time(second),
    Exp = maps:get(<<"exp">>, Claims, 0),
    case Now < Exp of
        true  -> {ok, Claims};
        false -> {error, expired}
    end.
