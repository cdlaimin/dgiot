%%%-------------------------------------------------------------------
%%% @author jonhl
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 30. 5月 2021 7:08
%%%-------------------------------------------------------------------
-module(dgiot_map).
-author("jonhl").
-export([with/2, get/2, merge/2]).
-export([test_get/0, test_merge/0]).
-export([test_map/0, map/2]).
%% ----------------------------------- unflatten flatten 不需要了，后面会去除，用map可以实时逆扁平化过程，td的扁平化通过物模型映射来完成 ------------%%
-export([flatten/1, flatten/2, unflatten/1, unflatten/2]).

merge(Data, NewData) ->
    maps:fold(
        fun(NewKey, NewValue, Acc) ->
            case maps:find(NewKey, Acc) of
                {ok, Value} when is_map(Value) and is_map(NewValue) ->
                    Acc#{NewKey => merge(Value, NewValue)};
                _ ->
                    Acc#{NewKey => NewValue}
            end
        end, Data, NewData).


with(Keys, Data) ->
    with(Keys, Data, #{}).

with([], _Data, Acc) ->
    Acc;
with([Key | Keys], Data, Acc) ->
    Map = get(Key, Data),
    with(Keys, Data, maps:merge(Acc, Map)).

get(Key, Data) ->
    case re:split(Key, <<"[.]">>, [{return, binary}, trim]) of
        List when length(List) == 1 ->
            case Data of
                #{Key := Value} ->
                    #{Key => Value};
                _ ->
                    #{}
            end;
        JsonKeys ->
            case value(JsonKeys, Data) of
                undefined -> #{};
                Value -> #{Key => Value}
            end
    end.

value([], Value) ->
    Value;
%%<<"data.[*].number">>   => number
%%value([<<"[*]", Tail/binary>> | Keys], Data) when is_list(Data) ->
%%    lists:foldl(fun(Num, Acc) ->
%%        BinNum = dgiot_utils:to_binary(Num),
%%        Acc ++ [value([<<"[", BinNum/binary, "]", Tail/binary>> | Keys], Data)]
%%                end, [], lists:seq(1, length(Data)));
%%<<"data.[0].number">>   => number
value([<<"[", Tail/binary>> | Keys], Data) when is_list(Data) ->
    Len = size(Tail) - 1,
    <<Index:Len/binary, _/binary>> = Tail,
    Num = dgiot_utils:to_int(Index),
    case length(Data) > Num of
        true ->
            NewValue = lists:nth(Num + 1, Data),
            value(Keys, NewValue);
        _ ->
            undefined
    end;
value([Key | Keys], Data) when is_map(Data) ->
    case Data of
        #{Key := Value} ->
            value(Keys, Value);
        _ ->
            undefined
    end;
value(_, _Value) ->
    undefined.

%% 支持变量和逻辑判断
%%{% ifnotequal var1 var2 %}
%%if: var1="foo" and var2="foo" are equal
%%{% endifnotequal %}
%%This is template 1.
%%
%%{{ test_var }}
%%
%%{% include "path2/template2" %}
map(Map, Template) ->
    case erlydtl:compile({template, Template}, dgiot_render, [{out_dir, false}]) of
        {ok, Render} ->
            {ok, IoList} = Render:render(Map),
%%            io:format("~p ~n",[decode(unicode:characters_to_binary(IoList))]),
            unicode:characters_to_binary(IoList);
        error ->
            {error, compile_error}
    end.


test_map() ->
    {file, Here} = code:is_loaded(?MODULE),
    Dir = filename:dirname(filename:dirname(Here)),
    Root = dgiot_httpc:url_join([Dir, "/priv/"]),
    TplPath = Root ++ "test.json",
    case catch file:read_file(TplPath) of
        {Err, _Reason} when Err == 'EXIT'; Err == error ->
            <<"">>;
        {ok, Template} ->
            map(#{
                <<"switch">> => 33331,
                <<"title">> => <<"cto">>,
                <<"label">> => 12343,
                <<"lsxage">> => 40
            }, Template)
    end.

test_get() ->
    Keys = [<<"content.i_out">>, <<"content.i_in">>, <<"name.[0].b.[0].c">>],
    Data = #{<<"content">> => #{<<"i_out">> => 1, <<"i_in">> => 9},
        <<"name">> => [
            #{<<"b">> => [#{<<"c">> => 9}]}
        ]
    },
    with(Keys, Data).

test_merge() ->
    A = #{1 => #{1 => 11}},
    B = #{1 => #{1 => 2, 2 => 3}, 2 => #{4 => 5}},
    merge(A, B).




%% ----------------------------------- unflatten flatten 不需要了，后面会去除，用map可以实时逆扁平化过程，td的扁平化通过物模型映射来完成 ------------%%
unflatten(Data) ->
    unflatten(Data, "_").

unflatten(List, Link) when is_list(List) ->
    lists:foldl(
        fun(X, Acc) ->
            Acc ++ [unflatten(X, Link)]
        end, [], List);

unflatten(Map, Link) when is_map(Map) ->
    maps:fold(
        fun(L, V, Acc) ->
            KList = lists:reverse(re:split(L, Link)),
            NewMap = get_map(KList, V),
            merge(Acc, NewMap)
        end, #{}, Map);

unflatten(Data, _) ->
    Data.

get_map(KList, V) ->
    lists:foldl(
        fun(X, Acc) ->
            Value = case maps:size(Acc) of
                        0 -> V;
                        _ -> Acc
                    end,
            case re:run(X, <<"\[[0-9]*\]">>) of
                {match, [{First, Len}]} ->
                    XList = dgiot_utils:to_list(X),
                    Key = lists:sublist(XList, 1, First),
                    Index = dgiot_utils:to_int(dgiot_utils:to_binary(lists:sublist(XList, First + 2, Len - 2))),
                    get_list(Key, Index, Value);
                _ ->
                    #{X => Value}
            end
        end, #{}, KList).

get_list(Key, Index, Value) when Index > 0 ->
    Head = lists:foldl(
        fun(_, Acc) ->
            Acc ++ [[]]
        end, [], lists:seq(1, Index)),
    #{dgiot_utils:to_binary(Key) => Head ++ [Value]};
get_list(Key, _, Value) ->
    #{dgiot_utils:to_binary(Key) => [Value]}.

flatten(Map) ->
    flatten(Map, <<"_">>).

flatten(Map, Link) ->
    case is_map(Map) of
        true ->
            maps:fold(
                fun(K, V, Acc) ->
                    maps:merge(Acc, flatten(<<K/binary>>, V, Link))
                end, #{}, Map);
        false ->
            {error, <<"wrong_type">>}

    end.

flatten(Head, Map, Link) ->
    case is_map(Map) of
        true ->
            maps:fold(
                fun(K, V, Acc) ->
                    maps:merge(Acc, flatten(<<Head/binary, Link/binary, K/binary>>, V, Link))
                end, #{}, Map);
        false ->
            #{<<Head/binary>> => Map}

    end.
