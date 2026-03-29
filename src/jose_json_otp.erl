%%%-------------------------------------------------------------------
%%% @doc
%%% jose JSON adapter using OTP 27+ built-in json module.
%%% Configured via: {jose, [{json_module, jose_json_otp}]}
%%% @end
%%%-------------------------------------------------------------------
-module(jose_json_otp).
-behaviour(jose_json).

-export([decode/1, encode/1]).

decode(Binary) ->
    json:decode(Binary).

encode(Term) ->
    iolist_to_binary(json:encode(Term)).
