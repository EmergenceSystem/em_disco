-module(em_disco_auth_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    issue_and_verify_test/1,
    expired_token_test/1,
    bad_signature_test/1,
    missing_token_test/1,
    empty_token_test/1,
    malformed_token_test/1
]).

all() -> [
    issue_and_verify_test,
    expired_token_test,
    bad_signature_test,
    missing_token_test,
    empty_token_test,
    malformed_token_test
].

init_per_suite(Config) ->
    application:ensure_all_started(jose),
    application:set_env(em_disco, jwt_secret, <<"test-secret-32-bytes-long!!">>),
    Config.

end_per_suite(_Config) ->
    ok.

issue_and_verify_test(_Config) ->
    Secret = <<"test-secret-32-bytes-long!!">>,
    Token = em_disco_auth:issue(<<"my_agent">>, Secret),
    ?assert(is_binary(Token)),
    {ok, Claims} = em_disco_auth:verify(Token),
    ?assertEqual(<<"my_agent">>, maps:get(<<"sub">>, Claims)).

expired_token_test(_Config) ->
    %% Manually craft an expired token
    Secret = <<"test-secret-32-bytes-long!!">>,
    JWK = jose_jwk:from_oct(Secret),
    Now = erlang:system_time(second),
    Claims = #{<<"sub">> => <<"old_agent">>, <<"iat">> => Now - 200, <<"exp">> => Now - 100},
    Signed = jose_jwt:sign(JWK, #{<<"alg">> => <<"HS256">>}, Claims),
    {_, Token} = jose_jws:compact(Signed),
    ?assertEqual({error, expired}, em_disco_auth:verify(Token)).

bad_signature_test(_Config) ->
    %% Token signed with a different secret
    WrongSecret = <<"wrong-secret-not-matching!!!!!">>,
    Token = em_disco_auth:issue(<<"agent">>, WrongSecret),
    ?assertEqual({error, invalid_signature}, em_disco_auth:verify(Token)).

missing_token_test(_Config) ->
    ?assertEqual({error, missing_token}, em_disco_auth:verify(undefined)).

empty_token_test(_Config) ->
    ?assertEqual({error, empty_token}, em_disco_auth:verify(<<>>)).

malformed_token_test(_Config) ->
    ?assertEqual({error, invalid_token}, em_disco_auth:verify(<<"not.a.jwt">>)).
