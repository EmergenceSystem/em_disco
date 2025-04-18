-module(register_handler).
-export([init/2]).

init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    FilterInfo = jsx:decode(Body, [return_maps]),
    Url = maps:get(<<"url">>, FilterInfo),
    
    % Register the filter URL using em_disco API function
    em_disco:register_filter(Url),
    
    Resp = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, <<>>, Req),
    
    {ok, Resp, State}.
