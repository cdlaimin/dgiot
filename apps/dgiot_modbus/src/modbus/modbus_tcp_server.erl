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

-module(modbus_tcp_server).
%%-author("johnliu").
%%-include_lib("dgiot/include/dgiot_socket.hrl").
%%-include("dgiot_meter.hrl").
%%%% API
%%-export([start/2]).
%%
%%%% TCP callback
%%-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, code_change/3]).
%%
%%start(Port, State) ->
%%    dgiot_tcp_server:child_spec(?MODULE, dgiot_utils:to_int(Port), State).
%%
%%%% =======================
%%%% tcp server start
%%%% {ok, State} | {stop, Reason}
%%init(TCPState) ->
%%    {ok, TCPState}.
%%
%%%%设备登录报文，登陆成功后，开始搜表
%%handle_info({tcp, DtuAddr}, #tcp{socket = Socket, state = #state{id = ChannelId, dtuaddr = <<>>} = State} = TCPState) when byte_size(DtuAddr) == 15 ->
%%    ?LOG(info,"DevAddr ~p ChannelId ~p", [DtuAddr, ChannelId]),
%%    DTUIP = dgiot_utils:get_ip(Socket),
%%%%    dgiot_meter:create_dtu(DtuAddr, ChannelId, DTUIP),
%%%%    {Ref, Step} = dgiot_smartmeter:search_meter(tcp, undefined, TCPState, 1),
%%    {noreply, TCPState#tcp{buff = <<>>, state = State#state{dtuaddr = DtuAddr, ref = Ref, step = Step}}};
%%
%%%%设备登录异常报文丢弃
%%handle_info({tcp, ErrorBuff}, #tcp{state = #state{dtuaddr = <<>>}} = TCPState) ->
%%    ?LOG(info,"ErrorBuff ~p ", [ErrorBuff]),
%%    {noreply, TCPState#tcp{buff = <<>>}};
%%
%%
%%%%定时器触发搜表
%%handle_info(search_meter, #tcp{state =  #state{ref = Ref} = State} = TCPState) ->
%%    {NewRef, Step} = dgiot_smartmeter:search_meter(tcp, Ref, TCPState, 1),
%%    {noreply, TCPState#tcp{buff = <<>>, state = State#state{ref = NewRef, step = Step}}};
%%
%%%%ACK报文触发搜表
%%handle_info({tcp, Buff}, #tcp{socket = Socket, state = #state{id = ChannelId, dtuaddr = DtuAddr, ref = Ref, step = search_meter} = State} = TCPState) ->
%%    ?LOG(info,"from_dev: search_meter Buff ~p", [dgiot_utils:binary_to_hex(Buff)]),
%%    lists:map(fun(X) ->
%%        case X of
%%            #{<<"addr">> := Addr} ->
%%                ?LOG(info,"from_dev: search_meter Addr ~p", [Addr]),
%%                DTUIP = dgiot_utils:get_ip(Socket),
%%                dgiot_meter:create_meter(dgiot_utils:binary_to_hex(Addr), ChannelId, DTUIP, DtuAddr);
%%            _ ->
%%                pass %%异常报文丢弃
%%        end
%%              end, dgiot_smartmeter:parse_frame(dlt645, Buff, [])),
%%    {NewRef, Step} = dgiot_smartmeter:search_meter(tcp, Ref, TCPState, 1),
%%    {noreply, TCPState#tcp{buff = <<>>, state = State#state{ref = NewRef, step = Step}}};
%%
%%%%接受抄表任务命令抄表
%%handle_info({deliver, _Topic, Msg}, #tcp{state = #state{id = ChannelId, step = read_meter}} = TCPState) ->
%%    case binary:split(dgiot_mqtt:get_topic(Msg), <<$/>>, [global, trim]) of
%%        [<<"thing">>, _ProductId, _DevAddr] ->
%%            #{<<"thingdata">> := ThingData} = jsx:decode(dgiot_mqtt:get_payload(Msg), [{labels, binary}, return_maps]),
%%            Payload = dgiot_smartmeter:to_frame(ThingData),
%%            dgiot_bridge:send_log(ChannelId, "from_task: ~ts:  ~ts ", [_Topic, unicode:characters_to_list(dgiot_mqtt:get_payload(Msg))]),
%%            ?LOG(info,"task->dev: Payload ~p", [dgiot_utils:binary_to_hex(Payload)]),
%%            dgiot_tcp_server:send(TCPState, Payload);
%%        _ ->
%%            pass
%%    end,
%%    {noreply, TCPState};
%%
%%%% 接收抄表任务的ACK报文
%%handle_info({tcp, Buff}, #tcp{state = #state{id = ChannelId, step = read_meter}} = TCPState) ->
%%    case dgiot_smartmeter:parse_frame(dlt645, Buff, []) of
%%        [#{<<"addr">> := Addr, <<"value">> := Value} | _] ->
%%            case dgiot_data:get({meter, ChannelId}) of
%%                {ProductId, _ACL, _Properties} -> DevAddr = dgiot_utils:binary_to_hex(Addr),
%%                    Topic = <<"thing/", ProductId/binary, "/", DevAddr/binary, "/post">>,
%%                    dgiot_mqtt:publish(DevAddr, Topic, dgiot_json:encode(Value));
%%                _ -> pass
%%            end;
%%        _ -> pass
%%    end,
%%    {noreply, TCPState#tcp{buff = <<>>}};
%%
%%%% 异常报文丢弃
%%%% {stop, TCPState} | {stop, Reason} | {ok, TCPState} | ok | stop
%%handle_info(_Info, TCPState) ->
%%    {noreply, TCPState}.
%%
%%handle_call(_Msg, _From, TCPState) ->
%%    {reply, ok, TCPState}.
%%
%%handle_cast(_Msg, TCPState) ->
%%    {noreply, TCPState}.
%%
%%terminate(_Reason, _TCPState) ->
%%    dgiot_metrics:dec(dgiot_meter, <<"dtu_login">>, 1),
%%    ok.
%%
%%code_change(_OldVsn, TCPState, _Extra) ->
%%    {ok, TCPState}.
