%%--------------------------------------------------------------------
%% Copyright (c) 2020 DGIOT Technologies Co., Ltd. All Rights Reserved.
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
-module(dlt376_decoder).
-author("gugm").
-include("dgiot_meter.hrl").
-include_lib("dgiot/include/logger.hrl").
-protocol([?DLT376]).


%% API
-export([
    parse_frame/2,
    to_frame/1,
    parse_value/2,
    process_message/2,
    process_message/3,
    process_message/4,
    check_Command/1,
    more_Check_Command/2,
    frame_write_param/1,
    get_childvalues/2,
    pn_to_da/1]).

-define(TYPE, ?DLT376).

%% 注册协议类型
-protocol_type(#{
    cType => ?TYPE,
    type => <<"energy">>,
    colum => 10,
    title => #{
        zh => <<"DLT376协议"/utf8>>
    },
    description => #{
        zh => <<"DLT376协议"/utf8>>
    }
}).
%% 注册协议参数
-params(#{
    <<"afn">> => #{
        order => 1,
        type => string,
        required => true,
        default => <<"00"/utf8>>,
        title => #{
            zh => <<"功能码(afn)"/utf8>>
        },
        description => #{
            zh => <<"功能码(afn)"/utf8>>
        }
    },
    <<"da">> => #{
        order => 2,
        type => string,
        required => true,
        default => <<"0000"/utf8>>,
        title => #{
            zh => <<"信息点(da)"/utf8>>
        },
        description => #{
            zh => <<"信息点(da)"/utf8>>
        }
    },
    <<"dt">> => #{
        order => 3,
        type => string,
        required => true,
        default => <<"0000"/utf8>>,
        title => #{
            zh => <<"信息类(dt)"/utf8>>
        },
        description => #{
            zh => <<"信息类(dt)"/utf8>>
        }
    },
    <<"type">> => #{
        order => 4,
        type => string,
        required => true,
        default => #{<<"value">> => <<"bytes">>, <<"label">> => <<"bytes">>},
        enum => [
            #{<<"value">> => <<"bytes">>, <<"label">> => <<"bytes">>},
            #{<<"value">> => <<"little">>, <<"label">> => <<"little">>},
            #{<<"value">> => <<"bit">>, <<"label">> => <<"bit">>}
        ],
        title => #{
            zh => <<"数据类型"/utf8>>
        },
        description => #{
            zh => <<"数据类型"/utf8>>
        }
    },
    <<"length">> => #{
        order => 5,
        type => integer,
        required => true,
        default => 2,
        title => #{
            zh => <<"长度"/utf8>>
        },
        description => #{
            zh => <<"长度"/utf8>>
        }
    }
}).


parse_frame(Buff, Opts) ->
    parse_frame(Buff, [], Opts).

parse_frame(<<>>, Acc, _Opts) ->
    {<<>>, Acc};

% 对于小于9的消息，独立decode
parse_frame(<<Rest/binary>> = Bin, Acc, _Opts) when byte_size(Rest) == 15 ->
    NewFrame = #{
        <<"msgtype">> => ?DLT645
    },
    Acc1 = Acc ++ [NewFrame],
    {Bin, Acc1};


%% DLT376协议
%% 68 32 00 32 00 68 C9 14 03 32 63 00 02 73 00 00 01 00 EB 16
%% 68 32 00 32 00 68 C9 00 10 01 00 00 02 70 00 00 01 00 4D 16
parse_frame(<<16#68, _:16, L2_low:6, _:2, L2_high:8, 16#68, C:8, A1:2/binary, A2:2/binary, A3:1/binary, AFN:8, SEQ:8, Rest/binary>> = Bin, Acc, Opts) ->
    Len = L2_high * 64 + L2_low,
    DLen = Len - 8,
    case byte_size(Rest) - 2 >= DLen of
        true ->
            case Rest of
                <<UserZone:DLen/binary, Crc:8, 16#16, Rest1/binary>> ->
                    CheckBuf = <<C:8, A1:2/binary, A2:2/binary, A3:1/binary, AFN:8, SEQ:8, UserZone/binary>>,
                    CheckCrc = dgiot_utils:get_parity(CheckBuf),
                    <<_Tpv:1, _FIRN:2, CON:1, _:4>> = <<SEQ:8>>,
                    % BinA = dgiot_utils:to_binary(A),
                    Acc1 =
                        case CheckCrc =:= Crc of
                            true ->
                                Frame = #{
                                    % <<"addr">> => <<"16#00,16#00",dlt645_proctol:reverse(A1)/binary,dlt645_proctol:reverse(A2)/binary>>,
                                    <<"addr">> => dgiot_utils:binary_to_hex(dlt376_proctol:encode_of_addr(A1, A2)),
                                    <<"command">> => C,
                                    <<"afn">> => AFN,
                                    <<"datalen">> => DLen,
                                    <<"msgtype">> => ?DLT376,
                                    <<"con">> => CON,
                                    <<"concentrator">> => <<A1:2/binary, A2:2/binary, A3:1/binary>>
                                },
                                case catch (parse_userzone(UserZone, Frame, Opts)) of
                                    {'EXIT', Reason} ->
                                        ?LOG(warning, "UserZone error,UserZone:~p, Reason:~p~n", [dgiot_utils:binary_to_hex(UserZone), Reason]),
                                        Acc;
                                    NewFrame ->
                                        Acc ++ [NewFrame]
                                end;
                            false ->
                                Acc
                        end,
                    parse_frame(Rest1, Acc1, Opts);
                _ ->
                    parse_frame(Rest, Acc, Opts)
            end;
        false ->
            {Bin, Acc}
    end;

parse_frame(<<_:8, Rest/binary>>, Acc, Opts) when byte_size(Rest) > 50 ->
    parse_frame(Rest, Acc, Opts);

parse_frame(<<Rest/binary>>, Acc, _Opts) ->
    {Rest, Acc}.



parse_userzone(UserZone, #{<<"msgtype">> := ?DLT376} = Frame, _Opts) ->
    check_Command(Frame#{<<"data">> => UserZone}).


% GW1376.1 确认报文
check_Command(State = #{<<"afn">> := 16#00}) ->
    State;

% GW1376.1 链路检测，登录
check_Command(State = #{<<"afn">> := 16#02, <<"data">> := <<16#00, 16#00, 16#01, 16#00, _Version/binary>>}) ->
    Frame = to_frame(State#{<<"command">> => 11,
        <<"afn">> => 0,
        <<"di">> => <<"00000400">>,
        <<"data">> => <<"020000010000">>}),
    State#{<<"frame">> => Frame};

% GW1376.1 链路检测，心跳
check_Command(State = #{<<"afn">> := 16#02, <<"data">> := <<16#00, 16#00, 16#04, 16#00, _Time/binary>>}) ->
    Frame = to_frame(State#{<<"command">> => 11,
        <<"afn">> => 0,
        <<"di">> => <<"00000400">>,
        <<"data">> => <<"020000040000">>}),
    State#{<<"frame">> => Frame};

% GW1376.1 读取集中器已存的电表信息
check_Command(State = #{<<"afn">> := 16#0A, <<"data">> := Data}) ->
    case Data of
        <<Di:4/bytes, Num:16/little, Rest/binary>> ->
            Value = disassemble(Num, Rest),
            State#{<<"di">> => Di, <<"value">> => Value};
        _ ->
            State
    end;

% GW1376.1 抄表返回的数据 16#0C 正向有功
check_Command(State = #{<<"afn">> := 16#0C}) ->
    Data = maps:get(<<"data">>, State, <<>>),
    case Data of
        <<Da:2/bytes, Dt:2/bytes, DTime:5/bytes, DNum:1/bytes, Rest1/bytes>> ->
            BinDi = dgiot_utils:to_hex(<<Da:2/bytes, Dt:2/bytes>>),
            BinDa = dgiot_utils:to_hex(Da),
            BinDt = dgiot_utils:to_hex(Dt),
            case dgiot_utils:to_hex(DTime) of
                <<"EEEEEEEEEE">> ->
                    State1 = #{
                        <<"afn">> => 16#0C,
                        <<"di">> => <<Da:2/bytes, Dt:2/bytes>>,
                        <<"time">> => dgiot_datetime:now_secs(),
                        <<"valuenum">> => DNum,
                        <<"addr">> => maps:get(<<"addr">>, State, <<>>),
                        <<"value">> => #{},
                        <<"childvalue">> => #{}
                    },
                    %%            费率长度
                    Ratelen = dgiot_utils:to_int(dgiot_utils:binary_to_hex(DNum)) * 5,
                    {NewState1, NewRest1} =
                        case Rest1 of
                            <<_DValue:5/bytes, Rates:Ratelen/bytes, Rest2/bytes>> ->
%%                            解析值和费率
                                State2 = decoder_value_Rate(1, BinDi, BinDa, BinDt, 0, Rates, State1),
                                {State2, Rest2};
                            _ ->
                                {State1, Rest1}
                        end,
                    more_Check_Command(NewState1, NewRest1);
                _ ->
                    State1 = #{
                        <<"afn">> => 16#0C,
                        <<"di">> => <<Da:2/bytes, Dt:2/bytes>>,
                        <<"time">> => dgiot_utils:to_hex(DTime),
                        <<"valuenum">> => DNum,
                        <<"addr">> => maps:get(<<"addr">>, State, <<>>),
                        <<"value">> => #{},
                        <<"childvalue">> => #{}
                    },
                    %%            费率长度
                    Ratelen = dgiot_utils:to_int(dgiot_utils:binary_to_hex(DNum)) * 5,
                    {NewState1, NewRest1} =
                        case Rest1 of
                            <<DValue:5/bytes, Rates:Ratelen/bytes, Rest2/bytes>> ->
%%                            解析值和费率
                                State2 = decoder_value_Rate(1, BinDi, BinDa, BinDt, DValue, Rates, State1),
                                {State2, Rest2};
                            _ ->
                                {State1, Rest1}
                        end,
                    more_Check_Command(NewState1, NewRest1)
            end;
        _ ->
            State
    end;

% GW1376.1 抄表返回的数据 16#0D 日正向有功
check_Command(State = #{<<"afn">> := 16#0D}) ->
    Data = maps:get(<<"data">>, State, <<>>),
    case Data of
        <<Dat:4/bytes, DTime:3/bytes, DNum:1/bytes, DValue:4/bytes, Rest1/bytes>> ->
            State1 = #{
                <<"afn">> => 16#0D,
                <<"di">> => Dat,
                <<"time">> => dgiot_utils:to_hex(DTime),
                <<"valuenum">> => DNum,
                <<"value">> => #{dgiot_utils:to_hex(Dat) => binary_to_value_dlt376_bcd(DValue)},
                <<"addr">> => maps:get(<<"addr">>, State, <<>>)
            },
%%            费率长度
            Ratelen = dgiot_utils:to_int(dgiot_utils:binary_to_hex(DNum)) * 4,
            case Rest1 of
                <<_:Ratelen/bytes, Rest2/bytes>> ->
                    more_Check_Command(State1, Rest2);
                _ ->
                    State1
            end;
        _ ->
            State
    end;

% DLT376 穿透转发返回
check_Command(State = #{<<"afn">> := 16#10}) ->
    Data = maps:get(<<"data">>, State, <<>>),
    case Data of
        % <<_:4/bytes,_:1/bytes,DLen2:8,DLen1:8,Rest/bytes>> ->
        %DLen = DLen1 * 255 + DLen2,
        <<_Di:4/bytes, _PassWay:1/bytes, DLen:16/little, Rest/bytes>> ->
            case Rest of
                <<DValue:DLen/bytes, _/bytes>> ->
                    {_, Frames} = dlt645_decoder:parse_frame(DValue, []),
                    %% #{<<"addr">>, <<"command">>, <<"msgtype">>, <<"di">>, <<"data">>, <<"value">>, <<"diff">>, <<"send_di">>}

                    ?LOG(warning, "GGM 160 check_Command:~p~n", [Frames]),
                    case Frames of
                        % 拉闸、合闸返回成功
                        [#{<<"command">> := 16#9C} | _] ->
                            Di = <<16#FE, 16#FE, 16#FE, 16#FE>>,
                            #{
                                <<"di">> => Di,%不做处理
                                <<"value">> => #{dgiot_utils:to_hex(Di) => 0},
                                <<"addr">> => maps:get(<<"addr">>, State, <<>>)
                            };
                        % 拉闸、合闸返回失败
                        [#{<<"command">> := 16#DC, <<"data">> := VData} | _] ->
                            Di = <<16#FE, 16#FE, 16#FE, 16#FD>>,
                            #{
                                <<"di">> => Di,%不做处理
                                <<"value">> => #{dgiot_utils:to_hex(Di) => dgiot_utils:to_hex(VData)},
                                <<"addr">> => maps:get(<<"addr">>, State, <<>>)
                            };
                        % 查询上一次合闸时间返回
                        [#{<<"command">> := 16#91, <<"di">> := <<16#1E, 16#00, 16#01, 16#01>>, <<"data">> := VData} | _] ->
                            Di = <<16#1E, 16#00, 16#01, 16#01>>,
                            #{
                                <<"di">> => Di,
                                <<"value">> => #{dgiot_utils:to_hex(Di) => dlt645_decoder:binary_to_dtime_dlt645_bcd(VData)},
                                <<"addr">> => maps:get(<<"addr">>, State, <<>>)
                            };
                        % 查询上一次拉闸时间返回
                        [#{<<"command">> := 16#91, <<"di">> := <<16#1D, 16#00, 16#01, 16#01>>, <<"data">> := VData} | _] ->
                            Di = <<16#1D, 16#00, 16#01, 16#01>>,
                            #{
                                <<"di">> => Di,
                                <<"value">> => #{dgiot_utils:to_hex(Di) => dlt645_decoder:binary_to_dtime_dlt645_bcd(VData)},
                                <<"addr">> => maps:get(<<"addr">>, State, <<>>)
                            };
                        %%[#{<<"addr">> => <<65,85,104,0,0,71>>,<<"command">> => 145,<<"data">> => <<66,0,0,0>>,<<"di">> => <<0,1,0,0>>,<<"diff">> => 0,<<"msgtype">> => <<"DLT645">>,<<"send_di">> => <<"00000100">>,<<"value">> => #{<<"00010000">> => 0.42}}]
                        [#{<<"command">> := 16#91, <<"addr">> := Addr, <<"di">> := Di, <<"value">> := Value} | _] ->
                            #{
                                <<"di">> => Di,
                                <<"value">> => Value,
                                <<"addr">> => maps:get(<<"addr">>, State, <<>>),
                                <<"meter">> => dgiot_utils:binary_to_hex(Addr)
                            };
                        _ ->
                            State
                    end;
                _ ->
                    State
            end;
        _ ->
            State
    end;

check_Command(State) ->
    State.

% GW1376.1 抄集中器多个电表返回的数据
more_Check_Command(#{<<"afn">> := 16#0C} = State, Rest) ->
    case Rest of
        <<Da:2/bytes, Dt:2/bytes, DTime:5/bytes, DNum:1/bytes, Rest1/bytes>> ->
            BinDi = dgiot_utils:to_hex(<<Da:2/bytes, Dt:2/bytes>>),
            BinDa = dgiot_utils:to_hex(Da),
            BinDt = dgiot_utils:to_hex(Dt),
            case dgiot_utils:to_hex(DTime) of
                <<"EEEEEEEEEE">> ->
                    %%            费率长度
                    Ratelen = dgiot_utils:to_int(dgiot_utils:binary_to_hex(DNum)) * 5,
                    {NewState1, NewRest1} =
                        case Rest1 of
                            <<_DValue:5/bytes, Rates:Ratelen/bytes, Rest2/bytes>> ->
%%                            解析值和费率
                                State2 = decoder_value_Rate(1, BinDi, BinDa, BinDt, 0, Rates, State),
                                {State2, Rest2};
                            _ ->
                                {State, Rest1}
                        end,
                    more_Check_Command(NewState1, NewRest1);
                _ ->
                    %%            费率长度
                    Ratelen = dgiot_utils:to_int(dgiot_utils:binary_to_hex(DNum)) * 5,
                    {NewState1, NewRest1} =
                        case Rest1 of
                            <<DValue:5/bytes, Rates:Ratelen/bytes, Rest2/bytes>> ->
%%                            解析值和费率
                                State2 = decoder_value_Rate(1, BinDi, BinDa, BinDt, DValue, Rates, State),
                                {State2, Rest2};
                            _ ->
                                {State, Rest1}
                        end,
                    more_Check_Command(NewState1, NewRest1)
            end;
        _ ->
            State
    end;

%% 日正向有功
more_Check_Command(#{<<"afn">> := 16#0D, <<"value">> := Value} = State, Rest) ->
    case Rest of
        <<Dat:4/bytes, _DTime:3/bytes, DNum:1/bytes, DValue:4/bytes, Rest1/bytes>> ->
            State1 = State#{<<"value">> => Value#{
                dgiot_utils:to_hex(Dat) => binary_to_value_dlt376_bcd(DValue)}
            },
%%            费率长度
            Ratelen = dgiot_utils:to_int(dgiot_utils:binary_to_hex(DNum)) * 4,
            case Rest1 of
                <<_:Ratelen/bytes, Rest2/bytes>> ->
                    more_Check_Command(State1, Rest2);
                _ ->
                    State1
            end;
        _ ->
            State
    end.

%% 组装成封包
to_frame(#{
    <<"command">> := C,
    <<"addr">> := Addr,
    <<"afn">> := AFN,
    <<"da">> := Da,
    <<"dt">> := Dt
} = _Msg) ->
%%    {ok, UserZone} = get_userzone(Msg),
    Da2 = dgiot_utils:hex_to_binary(Da),
    Dt2 = dgiot_utils:hex_to_binary(Dt),
    UserZone = <<C:8, Addr:5/bytes, AFN:8, 16#61, Da2/binary, Dt2/binary>>,
    Len = byte_size(UserZone) * 4 + 2,
    Crc = dgiot_utils:get_parity(UserZone),
    <<
        16#68,
        Len:16/little,
        Len:16/little,
        16#68,
        UserZone/binary,
        Crc:8,
        16#16
    >>;

to_frame(#{
    <<"command">> := C,
    <<"addr">> := Addr,
    <<"afn">> := AFN
} = Msg) when AFN == 1 orelse AFN == 4 orelse AFN == 5 orelse AFN == 6 orelse AFN == 10 ->
    {ok, UserZone} = get_userzone(Msg),
    UserData = <<C:8, Addr:5/bytes, AFN:8, 16#61, UserZone/binary>>,
    Len = byte_size(UserData) * 4 + 2,
    Crc = dgiot_utils:get_parity(<<C:8, Addr:5/bytes, AFN:8, 16#61, UserZone/binary>>),
    <<
        16#68,
        Len:16/little,
        Len:16/little,
        16#68,
        UserData/binary,
        Crc:8,
        16#16
    >>;

to_frame(#{
    <<"command">> := C,
    <<"addr">> := Addr,
    <<"afn">> := AFN
} = Msg) when AFN == 1 orelse AFN == 4 orelse AFN == 5 orelse AFN == 6 orelse AFN == 10 ->
    {ok, UserZone} = get_userzone(Msg),
    %%    todo 密码应该是从密码机传递过来
    Pwd = <<16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00, 16#00>>,
    UserData = <<UserZone/bytes, Pwd/bytes>>,
    Len = (byte_size(UserData) + 8) * 4 + 2,
    Crc = dgiot_utils:get_parity(<<C:8, Addr:5/bytes, AFN:8, 16#61, UserData/binary>>),
    <<
        16#68,
        Len:16/little,
        Len:16/little,
        16#68,
        C:8,
        Addr:5/bytes,
        AFN:8,
        16#61,
        UserData/binary,
        Crc:8,
        16#16
    >>;

%% 组装成封包
to_frame(#{
    <<"command">> := C,
    <<"concentrator">> := Addr,
    <<"afn">> := AFN
} = Msg) ->
%%    io:format("~s ~p Msg = ~p.~n", [?FILE, ?LINE, Msg]),
    {ok, UserZone} = get_userzone(Msg),
    UserZone1 = <<C:8, Addr:5/bytes, AFN:8, 16#61, UserZone/binary>>,
    Len = byte_size(UserZone1) * 4 + 2,
    Crc = dgiot_utils:get_parity(<<C:8, Addr:5/bytes, AFN:8, 16#61, UserZone/binary>>),
    <<
        16#68,
        Len:16/little,
        Len:16/little,
        16#68,
        C:8,
        Addr:5/bytes,
        AFN:8,
        16#61,
        UserZone/binary,
        Crc:8,
        16#16
    >>;

to_frame(Msg) ->
    io:format("~s ~p to_frame = ~p.~n", [?FILE, ?LINE, Msg]),
    <<>>.

% DLT376协议中把二进制转化成float
binary_to_value_dlt376_bcd(BinValue) ->
    RValue =
        case BinValue of
            <<Vf3:4, Vf4:4, Vf1:4, Vf2:4, V2:4, V1:4, V4:4, V3:4, V6:4, V5:4, _/binary>> ->
                Value = V6 * 100000 + V5 * 10000 + V4 * 1000 + V3 * 100 + V2 * 10 + V1 + Vf1 * 0.1 + Vf2 * 0.01 + Vf3 * 0.001 + Vf4 * 0.0001,
                Value;
            _ ->
                0.0
        end,
    RValue.

get_userzone(Msg) ->
    Di = maps:get(<<"di">>, Msg, <<>>),
    Data = maps:get(<<"data">>, Msg, <<>>),
    Di2 = dgiot_utils:hex_to_binary(Di),
    Data2 = dgiot_utils:hex_to_binary(Data),
    UserZone = <<Di2/binary, Data2/binary>>,
    {ok, UserZone}.

parse_value(Di, Data) ->
    {DI, Diff, SendDi} =
        case Di of
            <<16#05, 16#06, Di3:8, Di4:8>> when (Di3 >= 1 andalso Di3 =< 8) andalso (Di4 >= 1 andalso Di4 =< 63) ->
                {<<16#05, 16#06, Di3:8, 1>>, Di4 - 1, dgiot_utils:binary_to_hex(<<1, Di3:8, 6, 5>>)};
            <<16#00, D2:8, 16#FF, Di4:8>> when D2 >= 1 andalso D2 =< 10 andalso (Di4 >= 1 andalso Di4 =< 12) ->
                {<<16#00, D2:8, 16#FF, 1>>, Di4 - 1, dgiot_utils:binary_to_hex(<<1, 16#FF, D2:8, 0>>)};
            _ ->
                {Di, 0, dgiot_utils:binary_to_hex(dlt645_proctol:reverse(Di))}
        end,
    case dlt645_proctol:parse_data_to_json(DI, Data) of
        {Key, Value} ->
            ValueMap =
                case jsx:is_json(Value) of
                    false ->
                        #{Key => Value};
                    true ->
                        [{K1, _V1} | _] = Value0 = dgiot_json:decode(Value),
                        case size(K1) == 8 of
                            true ->
                                maps:from_list(Value0);
                            false ->
                                maps:from_list(lists:map(fun({K2, V2}) ->
                                    <<Di1:6/binary, _:2/binary, Di2/binary>> = K2,
                                    {<<Di1:6/binary, Di2/binary>>, V2}
                                                         end, Value0))

                        end
                end,
            {ValueMap, Diff, SendDi};
        _ -> {#{}, Diff, SendDi}
    end.


process_message(Frames, ChannelId) ->
    case Frames of
        % 返回读取上次合闸时间
        [#{<<"di">> := <<16#1E, 16#00, 16#01, 16#01>>, <<"addr">> := Addr, <<"value">> := Value} | _] ->
            case dgiot_data:get({meter, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    #{<<"productid">> => ProductId, <<"di">> => <<16#1E, 16#00, 16#01, 16#01>>, <<"addr">> => Addr, <<"value">> => dgiot_json:encode(Value)};
                _ -> #{}
            end;
        % 返回读取上次拉闸时间
        [#{<<"di">> := <<16#1D, 16#00, 16#01, 16#01>>, <<"addr">> := Addr, <<"value">> := Value} | _] ->
            case dgiot_data:get({meter, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    #{<<"productid">> => ProductId, <<"di">> => <<16#1D, 16#00, 16#01, 16#01>>, <<"addr">> => Addr, <<"value">> => dgiot_json:encode(Value)};
                _ -> #{}
            end;
        % 拉闸，合闸成功
        [#{<<"di">> := <<16#FE, 16#FE, 16#FE, 16#FE>>, <<"addr">> := Addr, <<"value">> := Value} | _] ->
            case dgiot_data:get({meter, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    #{<<"productid">> => ProductId, <<"di">> => <<16#FE, 16#FE, 16#FE, 16#FE>>, <<"addr">> => Addr, <<"value">> => dgiot_json:encode(Value)};
                _ -> #{}
            end;
        % 拉闸，合闸失败
        [#{<<"di">> := <<16#FE, 16#FE, 16#FE, 16#FD>>, <<"addr">> := Addr, <<"value">> := Value} | _] ->
            case dgiot_data:get({meter, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    #{<<"productid">> => ProductId, <<"di">> => <<16#FE, 16#FE, 16#FE, 16#FD>>, <<"addr">> => Addr, <<"value">> => dgiot_json:encode(Value)};
                _ -> #{}
            end;
        % 返回抄表数据
        [#{<<"di">> := <<16#01, 16#01, 16#01, 16#10>>, <<"addr">> := Addr, <<"value">> := Value} | _] ->
            case dgiot_data:get({meter, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    NewValue = dgiot_meter:get_ValueData(Value, ProductId),
                    #{<<"productid">> => ProductId, <<"addr">> => Addr, <<"value">> => NewValue};
                _ -> #{}
            end;
        %[#{<<"addr">> => <<"330100480000">>,<<"meter">> => <<>>, <<"di">> => <<0,1,0,0>>, <<"value">> => #{<<"00010000">> => 0}}]
        [#{<<"di">> := <<16#00, 16#01, 16#00, 16#00>>, <<"meter">> := MAddr, <<"value">> := Value} | _] ->
            case dgiot_data:get({meter, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    NewValue = dgiot_meter:get_ValueData(Value, ProductId),
                    #{<<"productid">> => ProductId, <<"addr">> => MAddr, <<"value">> => NewValue};
                _ -> #{}
            end;
        _ -> #{}
    end.


process_message(?DLT376, Frames, ChannelId) ->
    case Frames of
        [#{<<"addr">> := DevAddr, <<"value">> := Value, <<"childvalue">> := ChildValue} | _] ->
            case dgiot_data:get({dtu, ChannelId}) of
                {ProductId, _ACL, _Properties} ->
                    DeviceId = dgiot_parse_id:get_deviceid(ProductId, DevAddr),
                    NewValue = dgiot_meter:get_ValueData(Value, ProductId),
                    ChildValues = get_childvalues(DeviceId, ChildValue),
                    #{<<"productid">> => ProductId, <<"addr">> => DevAddr, <<"value">> => NewValue, <<"childvalues">> => ChildValues};
                _ -> pass
            end;
        _ ->
            pass
    end.

process_message(Frames, ChannelId, DTUIP, DtuId) ->
    [#{<<"afn">> := 16#0A, <<"di">> := <<16#00, 16#00, 16#02, 16#01>>, <<"addr">> := DevAddr, <<"value">> := Value} | _] = Frames,
    lists:map(fun(#{<<"addr">> := MeterAddr, <<"da">> := Da}) ->
        MAddr = dgiot_utils:binary_to_hex(MeterAddr),
        dgiot_meter:create_meter4G(MAddr, dgiot_utils:to_binary(Da), ChannelId, DTUIP, DtuId, DevAddr),
        timer:sleep(1 * 1000)
              end, Value).

get_childvalues(DeviceId, ChildValue) ->
    case dgiot_parse:query_object(<<"Device">>, #{<<"where">> => #{<<"parentId">> => DeviceId}}) of
        {ok, #{<<"results">> := ChildDevices}} ->
            lists:foldl(fun(#{<<"objectId">> := ChildId, <<"devaddr">> := Devaddr, <<"product">> := #{<<"objectId">> := ProductId}}, Acc) ->
                case dgiot_data:get({metertda, ChildId}) of
                    not_find ->
                        Acc;
                    {Da, _Dtuaddr} ->
                        DA = dgiot_utils:binary_to_hex(dlt376_decoder:pn_to_da(dgiot_utils:to_int(Da))),
                        case maps:find(DA, ChildValue) of
                            error ->
                                Acc;
                            {ok, Value} ->
                                NewValue = dgiot_meter:get_ValueData(Value, ProductId),
                                Acc ++ [#{<<"productid">> => ProductId, <<"addr">> => Devaddr, <<"value">> => NewValue}]
                        end
                end
                        end, [], ChildDevices);
        _ ->
            []

    end.

disassemble(Num, Rest) ->
    disassemble(Num, Rest, []).

disassemble(0, _, Acc) ->
    Acc;
disassemble(Num, Rest, Acc) ->
    <<_:2/binary, Pn:16/little, _:2/binary, Addr:6/binary, Psw:6/binary, _:2/binary, Collect:6/binary, _:1/binary, Rest1/binary>> = Rest,
    A = #{<<"pn">> => Pn,
        <<"da">> => Pn,
        <<"addr">> => dlt645_proctol:reverse(Addr),
        <<"psw">> => Psw,
        <<"collect">> => Collect},
    case lists:member(A, Acc) of
        true -> disassemble(Num - 1, Rest1, Acc);
        _ -> disassemble(Num - 1, Rest1, Acc ++ [A])
    end.

pn_to_da(Pn) when Pn == 0 ->
    <<16#00, 16#00>>;


pn_to_da(Pn) when (Pn rem 8) == 0 ->
    Di1 = Pn div 8,
    <<16#80, Di1:8>>;

pn_to_da(Pn) ->
    Da2 = Pn rem 8,
    Di1 = (Pn div 8) + 1,
    case Da2 of
        1 -> <<16#01, Di1:8>>;
        2 -> <<16#02, Di1:8>>;
        3 -> <<16#04, Di1:8>>;
        4 -> <<16#08, Di1:8>>;
        5 -> <<16#10, Di1:8>>;
        6 -> <<16#20, Di1:8>>;
        7 -> <<16#40, Di1:8>>;
        0 -> <<16#80, Di1:8>>
    end.


%%#{
%%<<"AFN040201_07">> =>
%%#{<<"AFN040201_07">> => <<"150711022766">>,
%%  <<"_dgiotprotocol">> => <<"GW376">>,
%%  <<"dataForm">> => #{<<"byteType">> => <<"bytes">>,
%%                      <<"bytes">> => <<"6">>},
%%<<"sessiontoken">> => <<>>},
%%<<"AFN040201_10">> =>
%%#{<<"AFN040201_10">> => <<"4">>,
%%<<"_dgiotprotocol">> => <<"GW376">>,
%%<<"dataForm">> =>
%%#{<<"byteType">> => <<"bytes">>,
%%<<"bytes">> => <<"1">>},
%%<<"sessiontoken">> => <<>>},
%%<<"AFN040201_11">> =>
%%#{<<"AFN040201_11">> => <<"5">>,
%%<<"_dgiotprotocol">> => <<"GW376">>,
%%<<"dataForm">> =>
%%#{<<"byteType">> => <<"bit">>,
%%<<"bytes">> => <<"4">>},
%%<<"sessiontoken">> => <<>>},
%%<<"AFN040201_12">> =>
%%#{<<"AFN040201_12">> => <<"1">>,
%%<<"_dgiotprotocol">> => <<"GW376">>,
%%<<"dataForm">> =>
%%#{<<"byteType">> => <<"bit">>,
%%<<"bytes">> => <<"4">>},
%%<<"sessiontoken">> => <<>>}}
%% ConAddr = <<"000033010048">>,
frame_write_param(#{<<"concentrator">> := ConAddr, <<"payload">> := Frame}) ->
    Length = length(maps:keys(Frame)),
%%    io:format("~s ~p SortFrame   ~p.~n", [?FILE, ?LINE, Length]),
    {BitList, Afn, Da, Fn} =
        lists:foldl(fun(Index, {Acc, A, D, F}) ->
            case maps:find(Index, Frame) of
                {ok, #{<<"value">> := Value, <<"dataSource">> := DataSource}} ->
                    get_bitlist(Value, DataSource, Acc);
                _ ->
                    {Acc, A, D, F}
            end
                    end, {[], 0, <<>>, <<>>}, lists:seq(1, Length)),
%%    io:format("~s ~p BitList = ~p.~n", [?FILE, ?LINE, BitList]),
    UserZone = <<<<V:BitLen>> || {V, BitLen} <- BitList>>,
%%    io:format("~s ~p UserZone  ~p. Afn ~p ~n", [?FILE, ?LINE, dgiot_utils:binary_to_hex(UserZone), Afn]),
    UserData = add_to_userzone(UserZone, Afn, Fn),
    dlt376_decoder:to_frame(#{<<"command">> => 16#4B,
        <<"addr">> => concentrator_to_addr(ConAddr),
        <<"afn">> => dgiot_utils:to_int(Afn),
        <<"di">> => <<Da/bytes, Fn/bytes>>,
        <<"data">> => dgiot_utils:binary_to_hex(UserData)}).

get_values(Acc, Data) ->
    lists:foldl(fun(V, Acc1) ->
        Acc1 ++ [{V, 8}]
                end, Acc, binary_to_list(Data)).

%% 下发指令
get_bitlist(Value, #{<<"afn">> := AFN, <<"da">> := DA, <<"dt">> := FN, <<"length">> := Len, <<"type">> := Type}, Acc) ->
    case Type of
        <<"bytes">> ->
            NewValue = dlt645_proctol:reverse(dgiot_utils:hex_to_binary(Value)),
%%            io:format("~s ~p NewValue   ~p.~n", [?FILE, ?LINE, dgiot_utils:binary_to_hex(NewValue)]),
            {get_values(Acc, NewValue), AFN, DA, FN};
        <<"little">> ->
            NewValue = dgiot_utils:to_int(Value),
            L = dgiot_utils:to_int(Len),
            Len1 = L * 8,
%%            io:format("~s ~p NewValue   ~p.~n", [?FILE, ?LINE, dgiot_utils:binary_to_hex(NewValue)]),
            {get_values(Acc, <<NewValue:Len1/little>>), AFN, DA, FN};
        <<"bit">> ->
            NewValue = dgiot_utils:to_int(Value),
            L = dgiot_utils:to_int(Len),
%%            io:format("~s ~p NewValue   ~p.~n", [?FILE, ?LINE, dgiot_utils:binary_to_hex(NewValue)]),
            {Acc ++ [{NewValue, L}], AFN, DA, FN}
    end.

add_to_userzone(UserZone, _Afn, _Fn) ->
    UserZone.

concentrator_to_addr(ConAddr) when byte_size(ConAddr) == 6 ->
    <<_:2/bytes, A11:2/bytes, A22:2/bytes>> = ConAddr,
    A1 = dlt645_proctol:reverse(A11),
    A2 = dlt645_proctol:reverse(A22),
    A3 = <<16#02>>,
    <<A1:2/bytes, A2:2/bytes, A3:1/bytes>>;
concentrator_to_addr(ConAddr) when byte_size(ConAddr) == 12 ->
    <<_:2/bytes, A11:2/bytes, A22:2/bytes>> = dgiot_utils:hex_to_binary(ConAddr),
    A1 = dlt645_proctol:reverse(A11),
    A2 = dlt645_proctol:reverse(A22),
    A3 = <<16#02>>,
    <<A1:2/bytes, A2:2/bytes, A3:1/bytes>>;
concentrator_to_addr(_ConAddr) ->
    <<16#00, 16#00, 16#00, 16#00, 16#00>>.

decoder_value_Rate(Index, BinDi, BinDa, BinDt, DValue, Rates, #{<<"afn">> := 16#0C, <<"value">> := Value, <<"childvalue">> := ChildValue} = State) ->
    NewBinDa =
        case maps:find(BinDa, ChildValue) of
            error ->
                #{};
            {ok, BinDa1} ->
                BinDa1
        end,
    BinIndex = dgiot_utils:to_binary(Index),
    case Rates of
        <<Rate:5/bytes, RateRest/bytes>> ->
            NewRate =
                case DValue of
                    0 ->
                        0;
                    _ ->
                        Rate
                end,
            State1 = State#{
                <<"value">> => Value#{
                    <<BinDi/binary, "">> => binary_to_value_dlt376_bcd(DValue),
                    <<BinDi/binary, "0", BinIndex/binary>> => binary_to_value_dlt376_bcd(NewRate)
                },
                <<"childvalue">> => ChildValue#{
                    <<BinDa/binary, "">> => NewBinDa#{
                        <<"0000", BinDt/binary>> => binary_to_value_dlt376_bcd(DValue),
                        <<"0000", BinDt/binary, "0", BinIndex/binary>> => binary_to_value_dlt376_bcd(NewRate)
                    }
                }
            },
            decoder_value_Rate(Index + 1, BinDi, BinDa, BinDt, DValue, RateRest, State1);
        _ ->
            State
    end;

decoder_value_Rate(_Index, _BinDi, _BinDa, _BinDt, _DValue, _Rates, State) ->
    State.
