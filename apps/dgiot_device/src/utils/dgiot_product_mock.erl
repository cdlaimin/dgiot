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

-module(dgiot_product_mock).
-author("jonliu").
-include("dgiot_device.hrl").
-include_lib("dgiot/include/logger.hrl").
-include_lib("dgiot_bridge/include/dgiot_bridge.hrl").
-dgiot_data("ets").
-export([init_ets/0, get_data/1]).


init_ets() ->
    dgiot_data:init(?MODULE).

%% 设备类型
get_data(ProductId) ->
    case dgiot_product:lookup_prod(ProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
            lists:foldl(
                fun
                    (#{<<"identifier">> := _Identifier, <<"dataForm">> := #{<<"strategy">> := <<"计算值"/utf8>>}}, Acc) ->
                        Acc;
                    (#{<<"identifier">> := Identifier, <<"dataType">> := Datatype}, Acc) ->
                        Last = dgiot_data:get(?MODULE, {ProductId, mock, Identifier}),
                        Value = get_value(Last, Datatype),
                        dgiot_data:insert(?MODULE, {ProductId, mock, Identifier}, Value),
                        Acc#{Identifier => Value}
                end, #{}, Props);
        _Error ->
            #{}
    end.


get_value(_Last, #{<<"type">> := <<"INT">>, <<"specs">> := #{<<"min">> := Min, <<"max">> := Max}}) ->
    Seed = (dgiot_utils:to_int(Max) - dgiot_utils:to_int(Min)),
    rand:uniform(Seed) + Min;

get_value(_Last, #{<<"type">> := <<"FLOAT">>, <<"specs">> := #{<<"min">> := Min, <<"max">> := Max}}) ->
    Seed = (dgiot_utils:to_int(Max) - dgiot_utils:to_int(Min)),
    rand:uniform(Seed) + Min;

get_value(_Last, #{<<"type">> := <<"DOUBLE">>, <<"specs">> := #{<<"min">> := Min, <<"max">> := Max}}) ->
    Seed = (dgiot_utils:to_int(Max) - dgiot_utils:to_int(Min)),
    rand:uniform(Seed);

get_value(_Last, #{<<"type">> := <<"STRING">>}) ->
    <<"mock">>;

get_value(_Last, #{<<"type">> := <<"BOOL">>}) ->
    rand:uniform(2) - 1;

get_value(_Last, #{<<"type">> := <<"ENUM">>, <<"specs">> := Spec}) ->
    List = maps:to_list(Spec),
    Pos = rand:uniform(length(List)),
    case lists:nth(List, Pos) of
        [{_K, V} | _] ->
            V;
        _ ->
            <<"mock">>
    end;

%% @todo 其它类型处理
get_value(_, _) ->
    0.

