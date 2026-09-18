-module(glroute_chat_ffi).

%% Generic JSON handling for the OpenAI-compatible proxy path.
%% Requests are kept as decoded maps so unknown fields (tools, tool_choice,
%% content parts, provider extensions) are forwarded untouched.
%% Requires OTP 27+ for the `json` module.

-export([parse_request/1, build_body/5, validate_response/1, to_sse/2, monotonic_time_ms/0, safe_run/1]).

monotonic_time_ms() ->
    erlang:monotonic_time(millisecond).

safe_run(Fun) ->
    try Fun()
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

parse_request(Body) ->
    try json:decode(Body) of
        #{<<"messages">> := [_ | _]} = Req ->
            Model =
                case maps:get(<<"model">>, Req, null) of
                    M when is_binary(M) -> M;
                    _ -> <<"default">>
                end,
            Stream = maps:get(<<"stream">>, Req, false) =:= true,
            IncludeUsage =
                case maps:get(<<"stream_options">>, Req, null) of
                    #{<<"include_usage">> := true} -> true;
                    _ -> false
                end,
            {ok, {chat_request, Req, Model, Stream, IncludeUsage}};
        Req when is_map(Req) ->
            {error, <<"missing or empty messages">>};
        _ ->
            {error, <<"request body must be a JSON object">>}
    catch
        _:_ -> {error, <<"invalid JSON">>}
    end.

build_body(Req, Model, Instructions, Temperature, MaxTokens) ->
    R0 = maps:without([<<"stream_options">>], Req),
    R1 = R0#{<<"model">> => Model, <<"stream">> => false},
    R2 = put_default([<<"temperature">>], <<"temperature">>, Temperature, R1),
    R3 = put_default(
        [<<"max_tokens">>, <<"max_completion_tokens">>], <<"max_tokens">>, MaxTokens, R2
    ),
    R4 =
        case Instructions of
            {some, Text} ->
                Messages = maps:get(<<"messages">>, R3),
                System = #{<<"role">> => <<"system">>, <<"content">> => Text},
                R3#{<<"messages">> => [System | Messages]};
            none ->
                R3
        end,
    iolist_to_binary(json:encode(R4)).

%% Request values win; agent-level settings only fill in missing fields.
put_default(_Keys, _Key, none, Req) ->
    Req;
put_default(Keys, Key, {some, Value}, Req) ->
    case lists:any(fun(K) -> maps:is_key(K, Req) end, Keys) of
        true -> Req;
        false -> Req#{Key => Value}
    end.

validate_response(Body) ->
    try json:decode(Body) of
        #{<<"choices">> := [_ | _]} = Resp ->
            case maps:get(<<"model">>, Resp, null) of
                M when is_binary(M) -> {ok, M};
                _ -> {ok, <<>>}
            end;
        #{<<"error">> := _} ->
            {error, <<"provider returned an error: ", (truncate(Body))/binary>>};
        _ ->
            {error, <<"no choices in provider response">>}
    catch
        _:_ -> {error, <<"provider response is not valid JSON">>}
    end.

%% Re-emit a complete (non-streaming) completion as OpenAI SSE chunks:
%% one delta chunk per choice, one finish chunk, optional usage chunk, [DONE].
to_sse(Body, IncludeUsage) ->
    Resp = json:decode(Body),
    Base = #{
        <<"id">> => maps:get(<<"id">>, Resp, <<"chatcmpl-glroute">>),
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => maps:get(<<"created">>, Resp, erlang:system_time(second)),
        <<"model">> => maps:get(<<"model">>, Resp, <<>>)
    },
    Choices = enumerate(maps:get(<<"choices">>, Resp, [])),
    DeltaChunk = Base#{
        <<"choices">> => [
            #{
                <<"index">> => choice_index(C, I),
                <<"delta">> => delta(maps:get(<<"message">>, C, #{})),
                <<"finish_reason">> => null
            }
         || {I, C} <- Choices
        ]
    },
    FinishChunk = Base#{
        <<"choices">> => [
            #{
                <<"index">> => choice_index(C, I),
                <<"delta">> => #{},
                <<"finish_reason">> => maps:get(<<"finish_reason">>, C, <<"stop">>)
            }
         || {I, C} <- Choices
        ]
    },
    UsageChunks =
        case {IncludeUsage, maps:get(<<"usage">>, Resp, null)} of
            {true, Usage} when is_map(Usage) ->
                [Base#{<<"choices">> => [], <<"usage">> => Usage}];
            _ ->
                []
        end,
    Events = [
        [<<"data: ">>, json:encode(Chunk), <<"\n\n">>]
     || Chunk <- [DeltaChunk, FinishChunk | UsageChunks]
    ],
    iolist_to_binary([Events, <<"data: [DONE]\n\n">>]).

delta(Message) when is_map(Message) ->
    M = maps:filter(fun(_K, V) -> V =/= null end, Message),
    case maps:get(<<"tool_calls">>, M, undefined) of
        ToolCalls when is_list(ToolCalls) ->
            M#{
                <<"tool_calls">> => [
                    TC#{<<"index">> => I}
                 || {I, TC} <- enumerate(ToolCalls), is_map(TC)
                ]
            };
        _ ->
            M
    end;
delta(_) ->
    #{}.

choice_index(Choice, Default) ->
    case maps:get(<<"index">>, Choice, null) of
        I when is_integer(I) -> I;
        _ -> Default
    end.

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).

truncate(Bin) when byte_size(Bin) > 500 ->
    <<Head:500/binary, _/binary>> = Bin,
    <<Head/binary, "...">>;
truncate(Bin) ->
    Bin.
