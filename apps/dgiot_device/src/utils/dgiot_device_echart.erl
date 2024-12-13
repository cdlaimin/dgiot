%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(dgiot_device_echart).
-author("kenneth").
-include("dgiot_device.hrl").
-include_lib("dgiot/include/logger.hrl").

-export([get_echart_data/5, get_echart_data/4]).
-export([get_data_by_month/4, get_data_by_echart_category/4, get_keys/2, get_table/2]).

get_echart_data(Channel, ProductId, DeviceId, Devaddr, Args) ->
    {Names, Results} =
        case dgiot_product:get_sub_tab(ProductId) of
            not_find ->
                get_echart_data(Channel, ProductId, DeviceId, Args);
            Subs when length(Subs) > 1 ->
                TableNames =
                    lists:foldl(fun(SubId, Acc) ->
                        SubDevid = dgiot_parse_id:get_deviceid(SubId, Devaddr),
                        Acc ++ [SubDevid]
                                end, [], Subs),
                get_echart_data(Channel, ProductId, TableNames, Args);
            _ ->
                get_echart_data(Channel, ProductId, DeviceId, Args)
        end,
    Interval = maps:get(<<"interval">>, Args),
    Chartdata = get_echart(ProductId, Results, Names, Interval),
    {ok, #{<<"chartData">> => Chartdata}}.

get_echart_data(Channel, ProductId, DeviceId, Args) ->
    Query = maps:without([<<"productid">>, <<"deviceid">>], Args),
    case dgiot_device_tdengine:get_history_data(Channel, ProductId, DeviceId, Query) of
        {TdNames, {ok, #{<<"results">> := TdResults}}} ->
            {TdNames, TdResults};
        _ ->
            {[], []}
    end.


format_line(ProductId, Interval, Line, Acc) when length(Line) > 1 ->
    Acc ++ [format_line_(ProductId, Interval, Line, #{})];
format_line(_ProductId, _Interval, _Line, Acc) ->
    Acc.

format_line_(_ProductId, _Interval, [], Acc) ->
    Acc;

format_line_(ProductId, Interval, [{<<"createdat">>, V} | Tail], Acc) ->
    NewV = dgiot_tdengine_field:get_time(V, Interval),
    NewAcc = Acc#{<<"日期"/utf8>> => NewV},
    format_line_(ProductId, Interval, Tail, NewAcc);

format_line_(ProductId, Interval, [{K, V} | Tail], Acc) ->
    NewAcc =
        case dgiot_product:get_product_identifier(ProductId, K) of
            #{<<"name">> := Name} ->
                Acc#{Name => V};
            _ ->
                Acc
        end,
    format_line_(ProductId, Interval, Tail, NewAcc).

format_results(_ProductId, _Interval, [], Acc) ->
    Acc;

format_results(ProductId, Interval, [Line | Results], Acc) ->
    NewAcc = format_line(ProductId, Interval, maps:to_list(Line), Acc),
    format_results(ProductId, Interval, Results, NewAcc).

format_rows([], Acc) ->
    Acc;

format_rows([Row | Rows], Acc) ->
    Date = maps:get(<<"日期"/utf8>>, Row, dgiot_datetime:format(dgiot_datetime:to_localtime(dgiot_datetime:now_secs()), <<"YY-MM-DD HH:NN:SS">>)),
    NewAcc =
        maps:fold(fun(K1, V1, Acc1) ->
            case maps:find(K1, Acc1) of
                error ->
                    Acc1#{K1 => [#{<<"日期"/utf8>> => Date, K1 => V1}]};
                {ok, V2} ->
                    Acc1#{K1 => V2 ++ [#{<<"日期"/utf8>> => Date, K1 => V1}]}
            end
                  end, Acc, maps:without([<<"日期"/utf8>>], Row)),
    format_rows(Rows, NewAcc).

format_childrows(_ProductId, [], Acc) ->
    Acc;

format_childrows(ProductId, [{K, V} | ChildRows], Acc) ->
    Unit =
        case dgiot_product:get_product_identifier(ProductId, K) of
            #{<<"dataType">> := #{<<"specs">> := #{<<"unit">> := Unit1}}} ->
                Unit1;
            _ ->
                <<"">>
        end,
    NewAcc = Acc ++ [#{<<"columns">> => [<<"日期"/utf8>>, K], <<"rows">> => V, <<"unit">> => Unit}],
    format_childrows(ProductId, ChildRows, NewAcc).

get_echart(ProductId, Results, Names, Interval) ->
    Columns = [<<"日期"/utf8>>] ++ Names,
    Rows = format_results(ProductId, Interval, Results, []),
%%    io:format("~s ~p Rows = ~ts.~n", [?FILE, ?LINE, unicode:characters_to_list(dgiot_json:encode(Rows))]),
    ChildRows = format_rows(Rows, #{}),
%%    io:format("~s ~p ChildRows = ~p.~n", [?FILE, ?LINE, ChildRows]),
    Child = format_childrows(ProductId, maps:to_list(ChildRows), []),
%%    io:format("~s ~p Child = ~p.~n", [?FILE, ?LINE, Child]),
    #{<<"columns">> => Columns, <<"rows">> => Rows, <<"child">> => Child}.

%%判断目标keys是否累计并根据结果设置Function
%% 遍历产品keys和目标keys得到目标keys是否累计
%%根据是否累计将keys分到sum和last
%%针对sum和last分别配置参数并调用history函数
%%调用history
%%get_data_by_month(Channel, ProductId, DeviceId,Args)
get_data_by_month(Channel, ProductId, DeviceId, Args) ->
%%    io:format("~s ~p Channel = ~p , ProductId = ~p, DeviceId = ~p    ~n",[?FILE,?LINE,Channel, ProductId, DeviceId]),
%%           由月份获得起止时间
    {ok, Count} = maps:find(<<"month_count">>, Args),
    {StartTime, EndTime} = dgiot_datetime:last_month(Count),
%%            取得key并分割转为list
    {ok, K} = maps:find(<<"keys">>, Args),
    Keys = re:split(K, ","),
%%            由key提取其accu属性并生成sql命令
    Res = case dgiot_product:lookup_prod(ProductId) of
              {ok, Product} ->
%%                            io:format("~s ~p Product =~p , Keys = ~p ~n",[?FILE,?LINE,Product,Keys]),
                  get_keys(Product, Keys);
              _ ->
                  error
          end,
%%            io:format("~s ~p Res = ~p~n",[?FILE,?LINE,Res]),
    {ok, Sql} = maps:find(<<"sql">>, Res),
    {ok, Name_and_nuit} = maps:find(<<"name_and_unit">>, Res),
%%            配置参数
    Interval = <<"1d">>,
    %%传入参数获得结果
    case dgiot_device_tdengine:get_history_data2(Sql, Channel, DeviceId, Interval, ProductId, StartTime, EndTime) of
%%                判断结果并转换格式
        {ok, #{<<"results">> := Results}} ->
%%                    io:format("~s ~p Results = ~p,Name_and_nuit = ~p ~n",[?FILE,?LINE,Results,Name_and_nuit]),
            Tabledata = get_table(Results, Name_and_nuit),
%%                    io:format("~s ~p Tabledata = ~p ~n",[?FILE,?LINE,Tabledata]),
            {ok, Tabledata};
        _ ->
            {ok, #{<<"code">> => 400, <<"msg">> => <<"no data">>}}
    end.

get_keys(#{<<"thing">> := #{<<"properties">> := Properties}}, [<<"*">>]) ->
    lists:foldl(
        fun(X, Acc) ->
%%        io:format("~s ~p Acc = ~p ~n",[?FILE,?LINE,Acc]),
            case X of
                #{<<"identifier">> := Identifier, <<"isaccumulate">> := true, <<"name">> := Name, <<"identifier">> := Key, <<"dataType">> := #{<<"specs">> := #{<<"unit">> := Unit}}} ->
                    case Acc of
                        #{<<"sql">> := Sql, <<"name_and_unit">> := Map} ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                            #{<<"sql">> => <<Sql/binary, ", sum(", Identifier/binary, ")">>, <<"name_and_unit">> => Map#{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}};
                        _ ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                            #{<<"sql">> => <<" sum(", Identifier/binary, ")">>, <<"name_and_unit">> => #{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}}
                    end;
                #{<<"identifier">> := Identifier, <<"isaccumulate">> := false, <<"name">> := Name, <<"identifier">> := Key, <<"dataType">> := #{<<"specs">> := #{<<"unit">> := Unit}}} ->
                    case Acc of
                        #{<<"sql">> := Sql, <<"name_and_unit">> := Map} ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                            #{<<"sql">> => <<Sql/binary, ", last(", Identifier/binary, ")">>, <<"name_and_unit">> => Map#{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}};
                        _ ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                            #{<<"sql">> => <<" last(", Identifier/binary, ")">>, <<"name_and_unit">> => #{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}}
                    end;
                _ ->
%%                    io:format("~s ~p Property = ~p ~n",[?FILE,?LINE,X]),
                    Acc
            end
        end, #{}, Properties);

get_keys(#{<<"thing">> := #{<<"properties">> := Properties}}, Keys) ->
    lists:foldl(fun(X, Acc) ->
        case X of
            #{<<"identifier">> := Identifier, <<"isaccumulate">> := true, <<"name">> := Name, <<"identifier">> := Key, <<"dataType">> := #{<<"specs">> := #{<<"unit">> := Unit}}} ->
                case lists:member(Identifier, Keys) of
                    true ->
                        case Acc of
                            #{<<"sql">> := Sql, <<"name_and_unit">> := Map} ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                                #{<<"sql">> => <<Sql/binary, ", sum(", Identifier/binary, ")">>, <<"name_and_unit">> => Map#{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}};
                            _ ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                                #{<<"sql">> => <<" sum(", Identifier/binary, ")">>, <<"name_and_unit">> => #{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}}
                        end;
                    false ->
                        Acc
                end;

            #{<<"identifier">> := Identifier, <<"isaccumulate">> := false, <<"name">> := Name, <<"identifier">> := Key, <<"dataType">> := #{<<"specs">> := #{<<"unit">> := Unit}}} ->
                case lists:member(Identifier, Keys) of
                    true ->
                        case Acc of
                            #{<<"sql">> := Sql, <<"name_and_unit">> := Map} ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                                #{<<"sql">> => <<Sql/binary, ", last(", Identifier/binary, ")">>, <<"name_and_unit">> => Map#{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}};
                            _ ->
%%                        io:format("~s ~p Key = ~p ~n",[?FILE,?LINE,Key]),
                                #{<<"sql">> => <<" last(", Identifier/binary, ")">>, <<"name_and_unit">> => #{<<Key/binary>> => #{<<"name">> => <<Name/binary>>, <<"unit">> => <<Unit/binary>>}}}
                        end;
                    false -> Acc
                end;
            _ ->
                Acc

        end
                end, #{}, Properties).

get_table(Results, Name_and_nuit) ->
    {TableData, Count} = lists:foldl(fun(X, Acc) ->
        Res = maps:fold(fun(K, V, Init) ->
            case K of
                <<"createdat">> ->
                    Init#{<<"时间"/utf8>> => V};
                _ ->
                    case binary:match(K, <<"last">>) of
                        {0, 4} ->
                            Last_Key = binary:part(K, 5, byte_size(K) - 6),
                            case maps:find(<<Last_Key/binary>>, Name_and_nuit) of
                                {ok, Map} ->
                                    Name = maps:get(<<"name">>, Map, K),
                                    Unit = maps:get(<<"unit">>, Map, <<"">>),
                                    K_with_unit = case V of
                                                      null -> <<"-">>;
                                                      _ ->
                                                          NewK = dgiot_utils:to_binary(V),
                                                          <<NewK/binary, Unit/binary>>
                                                  end,
                                    Init#{<<Name/binary>> => <<K_with_unit/binary>>};
                                error ->
                                    Init#{<<K/binary>> => V}
                            end;
                        _ ->
                            case binary:match(K, <<"sum">>) of
                                {0, 3} ->
                                    Sum_Key = binary:part(K, 4, byte_size(K) - 5),
                                    case maps:find(<<Sum_Key/binary>>, Name_and_nuit) of
                                        {ok, Map} ->
                                            Name = maps:get(<<"name">>, Map, K),
                                            Unit = maps:get(<<"unit">>, Map, <<"">>),
                                            K_with_unit = case V of
                                                              null -> <<"-">>;
                                                              _ ->
                                                                  NewK = dgiot_utils:to_binary(V),
                                                                  <<NewK/binary, Unit/binary>>
                                                          end,
                                            Init#{<<Name/binary>> => <<K_with_unit/binary>>};
                                        errgor ->
                                            Init#{<<K/binary>> => V}
                                    end;
                                _ ->
                                    Init#{<<K/binary>> => V}
                            end
                    end
            end
                        end, #{}, X),
        {D, N} = Acc,
        {D ++ [Res#{<<"序号"/utf8>> => N + 1}], N + 1}
                                     end, {[], 0}, Results),
    #{<<"status">> => 0, <<"msg">> => <<"ok">>, <<"data">> => #{<<"counts">> => Count, <<"rows">> => TableData}}.


get_data_by_echart_category(Channel, ProductId, DeviceId, Args) ->
    %%    io:format("~s ~p Channel = ~p , ProductId = ~p, DeviceId = ~p    ~n",[?FILE,?LINE,Channel, ProductId, DeviceId]),
    case dgiot_data:get({tdengine_os, Channel}) of
        <<"windows">> ->
            pass;
        _ ->
%%            io:format("~s ~p here ~n",[?FILE,?LINE]),
%%           由月份获得起止时间
            {ok, Count} = maps:find(<<"month_count">>, Args),
            {StartTime, EndTime} = dgiot_datetime:last_month(Count),
%%            取得key并分割转为list
            {ok, K} = maps:find(<<"keys">>, Args),
            Keys = re:split(K, ","),
%%            由key提取其accu属性并生成sql命令
            Res = case dgiot_product:lookup_prod(ProductId) of
                      {ok, Product} ->
%%                            io:format("~s ~p Product =~p , Keys = ~p ~n",[?FILE,?LINE,Product,Keys]),
                          get_keys(Product, Keys);
                      _ ->
                          error
                  end,
%%            io:format("~s ~p Res = ~p~n",[?FILE,?LINE,Res]),
            {ok, Sql} = maps:find(<<"sql">>, Res),
            {ok, Names} = maps:find(<<"names">>, Res),
%%            配置参数
            Interval = <<"1d">>,
            %%传入参数获得结果
            case dgiot_device_tdengine:get_history_data2(Sql, Channel, DeviceId, Interval, ProductId, StartTime, EndTime) of
%%                判断结果并转换格式
                {ok, #{<<"results">> := Results}} ->
%%                    io:format("~s ~p Results = ~p ~n",[?FILE,?LINE,Results]),
                    Tabledata = get_table(Results, Names),
%%                    io:format("~s ~p Tabledata = ~p ~n",[?FILE,?LINE,Tabledata]),
                    {ok, Tabledata};
                _ ->
                    {ok, #{<<"code">> => 400, <<"msg">> => <<"no data">>}}
            end


    end.
