-module(em_disco).
-export([
    start/0, 
    stop/0, 
    register_filter/1, 
    unregister_filter/1,
    query/1, 
    add_discovery_source/1, 
    remove_discovery_source/1,
    discover_filters/0
]).

-include_lib("embryo/src/embryo.hrl").

-define(TIMEOUT, 10000).
-define(DISCOVERY_INTERVAL, 120000).

%%% API Functions

start() ->
    io:format("[INFO] Starting em_disco application...~n"),
    application:ensure_all_started(em_disco),
    ets:new(filter_registry, [set, public, named_table]),
    ets:new(discovery_sources, [set, public, named_table]),
    spawn(fun() -> discovery_loop() end),
    io:format("[SUCCESS] em_disco application started with automatic filter discovery.~n"),
    ok.

stop() ->
    io:format("[INFO] Stopping em_disco application...~n"),
    application:stop(em_disco),
    io:format("[SUCCESS] em_disco application stopped.~n"),
    ok.

register_filter(Url) when is_binary(Url) ->
    io:format("[INFO] Registering filter (legacy method): ~p~n", [Url]),
    ets:insert(filter_registry, {Url, true}),
    io:format("[SUCCESS] Filter registered: ~p~n", [Url]),
    ok.

unregister_filter(Url) when is_binary(Url) ->
    io:format("[INFO] Unregistering filter (legacy method): ~p~n", [Url]),
    ets:delete(filter_registry, Url),
    io:format("[SUCCESS] Filter unregistered: ~p~n", [Url]),
    ok.

add_discovery_source(Source) when is_binary(Source) ->
    io:format("[INFO] Adding discovery source: ~p~n", [Source]),
    ets:insert(discovery_sources, {Source, true}),
    io:format("[SUCCESS] Discovery source added: ~p~n", [Source]),
    % Trigger immediate discovery
    spawn(fun() -> discover_filters() end),
    ok.

remove_discovery_source(Source) when is_binary(Source) ->
    io:format("[INFO] Removing discovery source: ~p~n", [Source]),
    ets:delete(discovery_sources, Source),
    io:format("[SUCCESS] Discovery source removed: ~p~n", [Source]),
    ok.

query(Body) ->
    io:format("[INFO] Starting query with body: ~p~n", [Body]),
    FilterUrls = get_filter_urls(),
    Results = call_filters(FilterUrls, Body),
    MergedResults = merge_lists_by_url(Results),
    MergedResults.

discovery_loop() ->
    discover_filters(),
    timer:sleep(?DISCOVERY_INTERVAL),
    discovery_loop().

discover_filters() ->
    io:format("[INFO] Running filter discovery...~n"),
    Sources = get_discovery_sources(),
    
    lists:foreach(fun(Source) ->
        discover_from_source(Source)
    end, Sources),

    discover_local_erlang_nodes(),
    
    io:format("[INFO] Filter discovery completed. Current filters: ~p~n", [get_filter_urls()]),
    ok.

discover_local_erlang_nodes() ->
    io:format("[INFO] Discovering local Erlang nodes responding to HTTP...~n"),
    % Configuration parameters
    BaseUrl = "http://localhost:",
    TestValue = <<"test">>,
    Ports = get_potential_erlang_ports(),
    
    % Check each port
    lists:foreach(
    fun(Port) ->
        spawn(fun() ->
            Url = list_to_binary(BaseUrl ++ integer_to_list(Port) ++ "/query"),
            case try_call_filter(Url, TestValue) of
                {ok, _} ->
                    io:format("[INFO] Found Erlang node responding at: ~s~n", [Url]),
                    register_filter(Url);
                {error, _Reason} ->
                    ok % Node not responding correctly, skip registration
            end
        end)
    end, Ports),
    ok.

% Try to call a potential filter using the same method as call_filter
try_call_filter(Url, RequestBody) ->
    StartTime = erlang:system_time(millisecond),
    io:format("[INFO] Testing potential filter ~p with body ~p~n", [Url, RequestBody]),
    
    UrlStr = binary_to_list(Url),
    TimeoutStr = integer_to_binary(?TIMEOUT),
    JsonBody = jsx:encode(#{
        <<"value">> => RequestBody,
        <<"timeout">> => TimeoutStr
    }),
    
    Headers = [{"content-type", "application/json"}],
    HttpOptions = [{timeout, ?TIMEOUT}, {connect_timeout, ?TIMEOUT}],
    
    try
        case httpc:request(post, {UrlStr, Headers, "application/json", JsonBody}, HttpOptions, []) of
            {ok, {{_, 200, _}, _RespHeaders, ResponseBody}} ->
                ElapsedTime = erlang:system_time(millisecond) - StartTime,
                io:format("[SUCCESS] Potential filter ~p responded in ~p ms.~n", [UrlStr, ElapsedTime]),
                {ok, ResponseBody};
            {ok, {{_, StatusCode, _}, _, _}} ->
                io:format("[DEBUG] Potential filter ~p returned HTTP status code ~p.~n", [UrlStr, StatusCode]),
                {error, {bad_status_code, StatusCode}};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        E:R:_ ->
            {error, {exception, {E, R}}}
    end.

% Get list of potential ports where Erlang nodes might be running
get_potential_erlang_ports() ->
    Range = lists:seq(8081, 8100),
    Range.

get_discovery_sources() ->
    case ets:info(discovery_sources) of
        undefined -> [];
        _ ->
            SourceList = ets:tab2list(discovery_sources),
            lists:map(fun({Source, _}) -> Source end, SourceList)
    end.

discover_from_source(Source) ->
    io:format("[INFO] Discovering filters from source: ~p~n", [Source]),
    try
        SourceStr = binary_to_list(Source),
        % Set shorter timeout for discovery
        HttpOptions = [{timeout, 5000}, {connect_timeout, 5000}],
        
        case httpc:request(get, {SourceStr, []}, HttpOptions, []) of
            {ok, {{_, 200, _}, _, ResponseBody}} ->
                Filters = parse_discovery_response(ResponseBody),
                lists:foreach(fun(FilterUrl) ->
                    register_filter(FilterUrl)
                end, Filters);
            {ok, {{_, StatusCode, _}, _, _}} ->
                io:format("[ERROR] Discovery source ~p returned HTTP status code ~p.~n", [SourceStr, StatusCode]);
            {error, Reason} ->
                io:format("[ERROR] HTTP request to discovery source ~p failed with reason ~p.~n", [SourceStr, Reason])
        end
    catch
        E:R:S ->
            io:format("[ERROR] Exception occurred while discovering from source ~p. Error: ~p:~p~nStacktrace: ~p~n", [Source, E, R, S])
    end.

parse_discovery_response(ResponseBody) ->
    try
        Normalized = normalize_json_string(ResponseBody),
        DecodedResponse = jsx:decode(Normalized, [return_maps]),
        case maps:get(<<"filters">>, DecodedResponse, undefined) of
            FilterList when is_list(FilterList) ->
                FilterList;
            _ ->
                io:format("[ERROR] Invalid discovery response format. Expected 'filters' array.~n"),
                []
        end
    catch
        error:badarg ->
            io:format("[ERROR] Failed to parse discovery response as JSON.~n"),
            extract_filter_urls_from_text(ResponseBody);
        E:R:S ->
            io:format("[ERROR] Unexpected error during discovery response parsing: ~p:~p~nStacktrace: ~p~n", [E, R, S]),
            []
    end.

extract_filter_urls_from_text(ResponseBody) ->
    % Fallback method: try to extract URLs from text using a simple pattern
    try
        Pattern = <<"https?://[^\\s\"']+">>,
        case re:run(ResponseBody, Pattern, [global, {capture, all, binary}]) of
            {match, Matches} ->
                [Url || [Url] <- Matches];
            nomatch ->
                []
        end
    catch
        _:_ -> []
    end.

get_filter_urls() ->
    case ets:info(filter_registry) of
        undefined ->
            io:format("[WARN] ETS table 'filter_registry' does not exist. Returning empty list.~n"),
            [];
        _ ->
            FilterUrls = ets:tab2list(filter_registry),
            lists:map(fun({Url, _}) -> Url end, FilterUrls)
    end.

call_filters(Urls, Body) ->
    Parent = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() ->
            Result = call_filter(Url, Body),
            Parent ! {Ref, Result}
        end),
        Ref
    end || Url <- Urls],
    collect_results(Refs, []).

call_filter(Url, RequestBody) ->
    StartTime = erlang:system_time(millisecond),
    io:format("[INFO] Calling filter ~p with body ~p~n", [Url, RequestBody]),

    UrlStr = binary_to_list(Url),
    TimeoutStr = integer_to_binary(?TIMEOUT div 1000 - 1),
    JsonBody = jsx:encode(#{
        <<"value">> => RequestBody,
        <<"timeout">> => TimeoutStr
    }),

    io:format("[DEBUG] JSON body prepared for filter ~p: ~s~n", [Url, JsonBody]),

    Headers = [{"content-type", "application/json"}],
    HttpOptions = [{timeout, ?TIMEOUT}, {connect_timeout, ?TIMEOUT}],

    try
        case httpc:request(post, {UrlStr, Headers, "application/json", JsonBody}, HttpOptions, []) of
            {ok, {{_, 200, _}, _RespHeaders, ResponseBody}} ->
                ElapsedTime = erlang:system_time(millisecond) - StartTime,
                io:format("[SUCCESS] Filter ~p responded in ~p ms. Response body: ~s~n", [UrlStr, ElapsedTime, ResponseBody]),
                parse_response(ResponseBody, Url);
            {ok, {{_, StatusCode, _}, _, _}} ->
                io:format("[ERROR] Filter ~p returned HTTP status code ~p.~n", [UrlStr, StatusCode]),
                {error, {bad_status_code, StatusCode}};
            {error, Reason} ->
                io:format("[ERROR] HTTP request to filter ~p failed with reason ~p.~n", [UrlStr, Reason]),
                % Remove unresponsive filter from registry
                ets:delete(filter_registry, Url),
                {error, Reason}
        end
    catch
        E:R:S ->
            io:format("[ERROR] Exception occurred while calling filter ~p. Error: ~p:~p~nStacktrace: ~p~n", [UrlStr, E, R, S]),
            {error, {exception, {E, R}}}
    end.

parse_response(ResponseBody, _Url) ->
    case safe_json_decode(ResponseBody) of
        {ok, EmbryoList} ->
            {ok, EmbryoList};
        {error, _} ->
            io:format("[WARN] JSON decode failed, attempting regex extraction.~n"),
            ExtractedData = extract_embryos(ResponseBody),
            {ok, ExtractedData}
    end.

safe_json_decode(ResponseBody) ->
    try
        Normalized = normalize_json_string(ResponseBody),
        DecodedResponse = jsx:decode(Normalized, [return_maps]),
        case maps:get(<<"embryo_list">>, DecodedResponse, undefined) of
            EmbryoList when is_list(EmbryoList) ->
                {ok, EmbryoList};
            _ ->
                io:format("[ERROR] Invalid response format. Decoded response: ~p~n", [DecodedResponse]),
                {error, invalid_response}
        end
    catch
        error:badarg ->
            {error, json_decode_error};
        E:R:S ->
            io:format("[ERROR] Unexpected error during JSON decode: ~p:~p~nStacktrace: ~p~n", [E, R, S]),
            {error, {unexpected_error, {E, R}}}
    end.

normalize_json_string(Binary) ->
    % Simple and safe way to handle potential encoding issues
    try
        % First attempt to ensure it's valid UTF-8
        case unicode:characters_to_binary(Binary) of
            {error, _, _} ->
                % If not valid UTF-8, replace problematic characters
                safe_binary_sanitize(Binary);
            {incomplete, _, _} ->
                % If incomplete UTF-8, replace problematic characters
                safe_binary_sanitize(Binary);
            ValidUtf8 ->
                ValidUtf8
        end
    catch
        _:_ ->
            % In case of any exception, fall back to simpler sanitization
            safe_binary_sanitize(Binary)
    end.

safe_binary_sanitize(Binary) ->
    % This is a safer approach that doesn't rely on complex regexps
    binary:replace(Binary,
                  [<<194, 160>>,  % non-breaking space
                   <<195>>,       % common part of many UTF-8 accented chars
                   <<194>>],      % common part of many UTF-8 special chars
                  <<32>>,         % regular space
                  [global]).

extract_embryos(ResponseBody) ->
    % Extract JSON-like structures from the response
    try
        % First try to find embryo_list key with its array value
        Pattern = <<"\"embryo_list\":\\s*\\[(.*?)\\]">>,
        case re:run(ResponseBody, Pattern, [dotall, {capture, [1], binary}]) of
            {match, [ListContent]} ->
                % Extract individual embryo objects
                extract_embryo_objects(ListContent);
            nomatch ->
                % If we can't find the embryo_list key, try to extract embryo structures directly
                EmbrPattern = <<"\\{\"properties\":\\s*\\{[^{}]*\\}\\}">>,
                case re:run(ResponseBody, EmbrPattern, [dotall, {capture, all, binary}, global]) of
                    {match, Matches} ->
                        [parse_single_embryo(Match) || [Match] <- Matches];
                    nomatch ->
                        []
                end
        end
    catch
        E:R:S ->
            io:format("[ERROR] Failed to extract embryos: ~p:~p~nStacktrace: ~p~n", [E, R, S]),
            []
    end.

extract_embryo_objects(ListContent) ->
    % Extract individual objects from the embryo_list array content
    Pattern = <<"\\{\"properties\":[^{}]*\\{[^{}]*\\}[^{}]*\\}">>,
    case re:run(ListContent, Pattern, [dotall, {capture, all, binary}, global]) of
        {match, Matches} ->
            [parse_single_embryo(Match) || [Match] <- Matches];
        nomatch ->
            []
    end.

parse_single_embryo(EmbryoJson) ->
    % Extract URL and resume properties from a single embryo JSON
    UrlPattern = <<"\"url\":\\s*\"([^\"]+)\"">>,
    ResumePattern = <<"\"resume\":\\s*\"([^\"]*)\"">>,

    Url = case re:run(EmbryoJson, UrlPattern, [{capture, [1], binary}]) of
        {match, [UrlValue]} -> UrlValue;
        nomatch -> <<"">>
    end,

    Resume = case re:run(EmbryoJson, ResumePattern, [{capture, [1], binary}]) of
        {match, [ResumeValue]} -> ResumeValue;
        nomatch -> <<"">>
    end,

    #embryo{properties = #{
        <<"url">> => unescape_json_string(Url),
        <<"resume">> => unescape_json_string(Resume)
    }}.

unescape_json_string(Str) ->
    % Unescape common JSON escape sequences
    S1 = binary:replace(Str, <<"\\\\">>, <<"\\">>, [global]),
    S2 = binary:replace(S1, <<"\\\/">>, <<"/">>, [global]),
    S3 = binary:replace(S2, <<"\\\"">>, <<"\"">>, [global]),
    S4 = binary:replace(S3, <<"\\n">>, <<"\n">>, [global]),
    S5 = binary:replace(S4, <<"\\r">>, <<"\r">>, [global]),
    S6 = binary:replace(S5, <<"\\t">>, <<"\t">>, [global]),
    % Handle unicode escapes
    handle_unicode_escapes(S6).

handle_unicode_escapes(Str) ->
    % For simplicity, we'll just handle basic unicode escape patterns
    Pattern = <<"\\\\u([0-9a-fA-F]{4})">>,
    case re:run(Str, Pattern, [{capture, all, binary}, global]) of
        {match, Matches} ->
            lists:foldl(fun([Full, HexCode], Acc) ->
                try
                    Code = binary_to_integer(HexCode, 16),
                    Char = unicode:characters_to_binary([Code], unicode, utf8),
                    binary:replace(Acc, Full, Char, [global])
                catch
                    _:_ -> Acc
                end
            end, Str, Matches);
        nomatch ->
            Str
    end.

collect_results([], Acc) ->
    Acc;
collect_results([Ref|Refs], Acc) ->
    receive
        {Ref, {ok, Result}} ->
            collect_results(Refs, [Result|Acc]);
        {Ref, {error, Error}} ->
            io:format("[WARN] Received error from a filter. Error details: ~p~n", [Error]),
            collect_results(Refs, Acc)
    after ?TIMEOUT ->
        io:format("[ERROR] Timeout occurred while waiting for filter responses.~n"),
        collect_results(Refs, Acc)
    end.

merge_lists_by_url(Lists) ->
    CombinedList = lists:flatten(Lists),
    {Result, _} = lists:foldl(fun merge_embryo/2, {[], sets:new()}, CombinedList),
    lists:reverse(Result).

merge_embryo(Data, {Acc, Seen}) ->
    Properties =
        case Data of
            #{<<"properties">> := Props} -> Props;
            #embryo{properties = Props} -> Props;
            _ -> #{}
        end,

    case maps:find(<<"url">>, Properties) of
        {ok, Url} when is_binary(Url) ->
            case sets:is_element(Url, Seen) of
                true ->
                    {Acc, Seen};
                false ->
                    {[Data | Acc], sets:add_element(Url, Seen)}
            end;
        _ ->
            io:format("Format invalid : ~p~n", [Properties]),
            {Acc, Seen}
    end.
