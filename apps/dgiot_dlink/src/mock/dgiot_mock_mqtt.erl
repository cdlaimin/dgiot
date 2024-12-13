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
-module(dgiot_mock_mqtt).
-author("johnliu").
-include_lib("dgiot/include/logger.hrl").
-include_lib("dgiot/include/dgiot_client.hrl").

-export([childspec/2, start/3]).

%% API
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

start(ChannelId, DeviceId, #{<<"auth">> := <<"ProductSecret">>} = Mock) ->
    case dgiot_device:lookup(DeviceId) of
        {ok, #{<<"devaddr">> := DevAddr, <<"productid">> := ProductId}} ->
            Options = #{
                host => "127.0.0.1",
                port => 1883,
                ssl => false,
                username => binary_to_list(ProductId),
                password => binary_to_list(dgiot_product:get_productSecret(ProductId)),
                clean_start => false
            },
            dgiot_client:start(<<ChannelId/binary, "_mockmqtt">>, <<ProductId/binary, "_", DevAddr/binary>>, #{<<"options">> => Options, <<"child">> => Mock});
        _ ->
            #{}
    end;

start(ChannelId, DeviceId, #{<<"auth">> := <<"DeviceSecret">>}) ->
    case dgiot_device:lookup(DeviceId) of
        {ok, #{<<"devaddr">> := DevAddr, <<"productid">> := ProductId, <<"devicesecret">> := DeviceSecret}} ->
            Options = #{
                host => "127.0.0.1",
                port => 1883,
                ssl => false,
                username => binary_to_list(ProductId),
                password => binary_to_list(DeviceSecret),
                clean_start => false
            },
%%            io:format("~s ~p DeviceId ~p DevAddr ~p ", [?FILE, ?LINE, DeviceId, DevAddr]),
            dgiot_client:start(<<ChannelId/binary, "_mockmqtt">>, <<ProductId/binary, "_", DevAddr/binary>>, #{<<"options">> => Options});
        _ ->
            #{}
    end.

childspec(ChannelId, ChannelArgs) ->
    Options = #{
        host => binary_to_list(maps:get(<<"address">>, ChannelArgs, <<"127.0.0.1">>)),
        port => maps:get(<<"port">>, ChannelArgs, 1883),
        ssl => maps:get(<<"ssl">>, ChannelArgs, false),
        username => binary_to_list(maps:get(<<"username">>, ChannelArgs, <<"anonymous">>)),
        password => binary_to_list(maps:get(<<"password">>, ChannelArgs, <<"password">>)),
        clean_start => maps:get(<<"clean_start">>, ChannelArgs, false)
    },
    Args = #{<<"channel">> => ChannelId, <<"mod">> => ?MODULE, <<"options">> => Options},
    dgiot_client:register(<<ChannelId/binary, "_mockmqtt">>, mqtt_client_sup, Args).

%%  callback
init(#dclient{channel = ChannelId, child = #{<<"endtime">> := EndTime1, <<"starttime">> := StartTime1} = Child} = State) ->
    Freq = dgiot_utils:to_int(maps:get(<<"freq">>, Child, 5)),
    StartTime = dgiot_utils:to_int(StartTime1),
    EndTime = dgiot_utils:to_int(EndTime1),
    NextTime = dgiot_client:get_nexttime(StartTime, Freq + 5),
    Count = dgiot_client:get_count(StartTime, EndTime, Freq),
    Rand =
        case maps:get(<<"rand">>, Child, true) of
            true ->
                dgiot_client:get_rand(Freq);
            _ ->
                0
        end,
    {ok, State#dclient{channel = dgiot_utils:to_binary(ChannelId), clock = #dclock{nexttime = NextTime + Rand, freq = Freq, count = Count, round = 0}}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({connect, Pid}, #dclient{channel = ChannelId, client = <<ProductId:10/binary, "_", DevAddr/binary>>} = Dclient) ->
    FirmwareTopic = <<"$dg/thing/", ProductId/binary, "/", DevAddr/binary, "/firmware/report">>,
    emqtt:publish(Pid, FirmwareTopic, jiffy:encode(#{<<"devaddr">> => DevAddr}), 1),  % cloud to edge
    ProfileTopic = <<"$dg/device/", ProductId/binary, "/", DevAddr/binary, "/profile">>,
    emqtt:subscribe(Pid, ProfileTopic, 1),
    update(ChannelId),
    {noreply, Dclient};

handle_info(disconnect, #dclient{channel = ChannelId} = Dclient) ->
    dgiot_bridge:send_log(ChannelId, "~s ~p  ~p ~n", [?FILE, ?LINE, dgiot_json:encode(#{<<"network">> => <<"disconnect">>})]),
    {noreply, Dclient};



handle_info(next_time, #dclient{channel = Channel, client = <<ProductId:10/binary, "_", DevAddr/binary>> = Client, userdata = UserData,
    clock = #dclock{round = Round, nexttime = NextTime, count = Count, freq = Freq} = Clock} = Dclient) ->
    dgiot_client:stop(Channel, Client, Count), %% ¼ì²éÊÇ·ñÐèÒªÍ£Ö¹ÈÎÎñ
    NewNextTime = dgiot_client:get_nexttime(NextTime, Freq),
    NewRound = Round + 1,
    PayLoad = dgiot_product_mock:get_data(ProductId),
    Topic = <<"$dg/thing/", ProductId/binary, "/", DevAddr/binary, "/properties/report">>,
    dgiot_mqtt_client:publish(UserData, Topic, jiffy:encode(PayLoad), 0),
    {noreply, Dclient#dclient{clock = Clock#dclock{nexttime = NewNextTime, count = Count - 1, round = NewRound}}};

handle_info({publish, #{payload := Payload, topic := Topic} = _Msg}, #dclient{channel = ChannelId} = State) ->
    io:format("~s ~p ChannelId ~p Topic ~p  Payload ~p  ~n", [?FILE, ?LINE, ChannelId, Topic, Payload]),
%%    dgiot_bridge:send_log(ChannelId, "cloud to edge: Topic ~p Payload ~p ~n", [Topic, Payload]),
%%    dgiot_mqtt:publish(ChannelId, Topic, Payload),
    {noreply, State};

handle_info({deliver, _, Msg}, #dclient{client = Client, channel = ChannelId} = State) ->
    case dgiot_mqtt:get_topic(Msg) of
        <<"forward/", Topic/binary>> ->
            dgiot_bridge:send_log(ChannelId, "edge  to cloud: Topic ~p Payload ~p ~n", [Topic, dgiot_mqtt:get_payload(Msg)]),
            emqtt:publish(Client, Topic, dgiot_mqtt:get_payload(Msg));
        _ -> pass
    end,
    {noreply, State};

handle_info(_Info, Dclient) ->
%%    ?LOG(info,"ecapturer ~p~n", [_Info]),
    {noreply, Dclient}.

terminate(_Reason, #dclient{channel = ChannelId, client = ClientId}) ->
%%    ?LOG(info,"_Reason ~p~n", [_Reason]),
    dgiot_client:stop(ChannelId, ClientId),
    update(ChannelId),
    ok.

code_change(_OldVsn, Dclient, _Extra) ->
    {ok, Dclient}.

update(ChannelId) ->
    dgiot_data:insert({<<"mqtt_online">>, dlink_metrics}, dgiot_client:count(ChannelId)).

