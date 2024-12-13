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

-module(dgiot_device_profile).
-author("jonhliu").
-include("dgiot_device.hrl").
-include_lib("dgiot_bridge/include/dgiot_bridge.hrl").
-include_lib("dgiot/include/logger.hrl").
-export([post/2, put/2, delete/3, publish/3, publish/4, update_profile/2, encode_profile/2]).

post('before', _BeforeData) ->
    ok;
post('after', _AfterData) ->
    ok.

%% 配置下发
put('before', #{<<"id">> := DeviceId, <<"profile">> := #{<<"type">> := <<"hex">>, <<"data">> := Data}} = Device) ->
    case dgiot_device:lookup(DeviceId) of
        {ok, #{<<"devaddr">> := Devaddr, <<"productid">> := ProductId}} ->
            dgiot_device:save_profile(Device#{<<"objectId">> => DeviceId, <<"product">> => #{<<"objectId">> => ProductId}}),
            ProfileTopic =
                case dgiot_product:lookup_prod(ProductId) of
                    {ok, #{<<"topics">> := #{<<"device_profile">> := ToipcTempl}}} ->
                        Topic = re:replace(ToipcTempl, <<"\\${productId}">>, ProductId, [{return, binary}]),
                        re:replace(Topic, <<"\\${deviceAddr}">>, Devaddr, [{return, binary}]);
                    _ ->
                        <<"$dg/device/", ProductId/binary, "/", Devaddr/binary, "/profile">>
                end,
            NewHex =
                case catch dgiot_utils:hex_to_binary(Data) of
                    {_, _} ->
                        Data;
                    Binary ->
                        Binary
                end,
            io:format("~s ~p ProfileTopic = ~p.~n", [?FILE, ?LINE, ProfileTopic]),
            dgiot_mqtt:publish(DeviceId, ProfileTopic, NewHex);
        _ ->
            pass
    end;

put('before', #{<<"id">> := DeviceId, <<"profile">> := UserProfile} = Device) ->
    case dgiot_device:lookup(DeviceId) of
        {ok, #{<<"devaddr">> := Devaddr, <<"productid">> := ProductId}} ->
            dgiot_device:save_profile(Device#{<<"objectId">> => DeviceId, <<"product">> => #{<<"objectId">> => ProductId}}),
            ProfileTopic =
                case dgiot_product:lookup_prod(ProductId) of
                    {ok, #{<<"topics">> := #{<<"device_profile">> := ToipcTempl}}} ->
                        Topic = re:replace(ToipcTempl, <<"\\${productId}">>, ProductId, [{return, binary}]),
                        re:replace(Topic, <<"\\${deviceAddr}">>, Devaddr, [{return, binary}]);
                    _ ->
                        <<"$dg/device/", ProductId/binary, "/", Devaddr/binary, "/profile">>
                end,
            dgiot_mqtt:publish(DeviceId, ProfileTopic, dgiot_json:encode(UserProfile));
        _ ->
            pass
    end;

put('after', #{<<"id">> := DeviceId, <<"profile">> := UserProfile}) ->
%%    io:format("~s ~p DeviceId ~p  Profile = ~p.~n", [?FILE, ?LINE, DeviceId, UserProfile]),
    dgiot_data:insert(?DEVICE_PROFILE, DeviceId, UserProfile);

put(_, _) ->
    ok.

delete('before', _BeforeData, _ProductId) ->
    ok;
delete('after', #{<<"objectId">> := DtuId}, _ProductId) ->
    dgiot_task:del_pnque(DtuId).

%% 配置同步
publish(ProductId, DeviceAddr, DeviceProfile) ->
    publish(ProductId, DeviceAddr, DeviceProfile, 2).

publish(ProductId, DeviceAddr, DeviceProfile, Delay) ->
    case dgiot_data:get({profile, channel}) of
        not_find ->
            pass;
        ChannelId ->
            dgiot_channelx:do_message(ChannelId, {sync_profile, self(), ProductId, DeviceAddr, DeviceProfile, Delay})
    end.

update_profile(DeviceId, NewProfile) ->
    case dgiot_parsex:get_object(<<"Device">>, DeviceId) of
        {ok, Device} ->
            OldProfile = maps:get(<<"profile">>, Device, #{}),
            dgiot_parsex:update_object(<<"Device">>, DeviceId, #{
                <<"profile">> => dgiot_map:merge(OldProfile, NewProfile)});
        _ ->
            pass
    end.

encode_profile(ProductId, Profile) ->
    case dgiot_parsex:get_object(<<"Product">>, ProductId) of
        {ok, #{<<"name">> := ProductName, <<"thing">> := #{<<"properties">> := Properties}}} ->
            lists:foldl(fun(X, Acc) ->
                case X of
                    #{<<"identifier">> := Identifier, <<"name">> := Name, <<"accessMode">> := <<"rw">>, <<"dataForm">> := DataForm, <<"dataSource">> := #{<<"_dlinkindex">> := Index} = DataSource} ->
                        case maps:find(Identifier, Profile) of
                            {ok, V} ->
                                Acc#{
                                    dgiot_utils:to_int(Index) => #{
                                        <<"value">> => V,
                                        <<"identifier">> => Identifier,
                                        <<"name">> => Name,
                                        <<"productname">> => ProductName,
                                        <<"dataSource">> => DataSource,
                                        <<"dataForm">> => DataForm
                                    }};
                            _ ->
                                Acc
                        end;
                    _ -> Acc
                end
                        end, #{}, Properties);
        false ->
            pass
    end.
