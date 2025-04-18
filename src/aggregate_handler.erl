-module(aggregate_handler).
-export([init/2]).

init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    
    % Query all filters using em_disco API function
    AggregatedList = em_disco:query(Body),
    
    % Return the aggregated results
    Response = jsx:encode(#{<<"embryo_list">> => AggregatedList}),
    Resp = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, Response, Req),
    
    {ok, Resp, State}.
