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

-module(dgiot_tcp2grpc_worker).
-author("johnliu").
-include_lib("dgiot/include/dgiot_socket.hrl").
-include_lib("dgiot/include/logger.hrl").

-define(TYPE, <<"DLINK">>).
-define(MAX_BUFF_SIZE, 1024).
-record(state, {
    id,
    mode = product,
    env = #{},
    devaddr = <<>>,
    productIds = <<>>
}).


%% TCP callback
-export([child_spec/3, init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, code_change/3]).

child_spec(Port, ChannleId, Mode) ->
    dgiot_tcp_server:child_spec(?MODULE, Port, #state{id = ChannleId, mode = dgiot_utils:to_atom(Mode)}).

%% =======================
%% {ok, State} | {stop, Reason}
init(#tcp{state = #state{id = ChannelId} = State} = TCPState) ->
    case dgiot_bridge:get_products(ChannelId) of
        {ok, ?TYPE, ProductIds} ->
            lists:map(fun(ProductId) ->
                do_cmd(ProductId, connection_ready, <<>>, TCPState)
                      end, ProductIds),
            NewState = State#state{productIds = ProductIds},
            {ok, TCPState#tcp{log = log_fun(ChannelId), state = NewState}};
        {error, not_find} ->
            {error, not_find_channel}
    end;

init(TCPState) ->
    {ok, TCPState}.

handle_info({deliver, _, Msg}, TCPState) ->
    Payload = dgiot_mqtt:get_payload(Msg),
    Topic = dgiot_mqtt:get_topic(Msg),
    case binary:split(Topic, <<$/>>, [global, trim]) of
        [<<"thing">>, ProductId, DevAddr, <<"tcp">>, <<"hex">>] ->
            DeviceId = dgiot_parse_id:get_deviceid(ProductId, DevAddr),
            dgiot_device:save_log(DeviceId, Payload, ['tcp_send']),
            dgiot_tcp_server:send(TCPState, dgiot_utils:hex_to_binary(dgiot_utils:trim_string(Payload))),
            {noreply, TCPState};
        _ ->
            case jsx:is_json(Payload) of
                true ->
                    case jsx:decode(Payload, [{labels, binary}, return_maps]) of
                        #{<<"cmd">> := <<"send">>} = Cmd ->
                            handle_info(Cmd, TCPState);
                        Info ->
                            handle_info(Info, TCPState)
                    end;
                false ->
                    {noreply, TCPState}
            end
    end;

%%  执行tcp状态机内的命令
handle_info(#{<<"cmd">> := Cmd, <<"data">> := Data, <<"productId">> := ProductId}, TCPState) ->
    do_cmd(ProductId, Cmd, Data, TCPState);

handle_info({tcp, Buff}, #tcp{state = #state{id = ChannelId, productIds = ProductIds}} = TCPState) ->
    dgiot_bridge:send_log(ChannelId, "Buff ~p", [Buff]),
    lists:map(fun(ProductId) ->
        do_cmd(ProductId, tcp, Buff, TCPState)
              end, ProductIds),
    {noreply, TCPState};

%% {stop, TCPState} | {stop, Reason} | {ok, TCPState} | ok | stop
handle_info(_Info, TCPState) ->
    {noreply, TCPState}.

handle_call(_Msg, _From, TCPState) ->
    {reply, ok, TCPState}.

handle_cast(_Msg, TCPState) ->
    {noreply, TCPState}.

terminate(_Reason, #tcp{state = #state{productIds = ProductIds}} = TCPState) ->
    lists:map(fun(ProductId) ->
        do_cmd(ProductId, terminate, _Reason, TCPState)
              end, ProductIds),
    ok;

terminate(_Reason, _TCPState) ->
    ok.

code_change(_OldVsn, TCPState, _Extra) ->
    {ok, TCPState}.

%% =======================
do_cmd(ProductId, Cmd, Data, #tcp{state = #state{id = ChannelId, mode = product} = State} = TCPState) ->
    case dgiot_hook:run_hook({tcp, ProductId}, [Cmd, Data, State]) of
        {ok, NewState} ->
            {noreply, TCPState#tcp{state = NewState}};
        {reply, ProductId, Payload, NewState} ->
            case dgiot_tcp_server:send(TCPState, Payload) of
                ok ->
                    ok;
                {error, Reason} ->
                    dgiot_bridge:send_log(ChannelId, ProductId, "Send Fail, ~p, CMD:~p", [Cmd, Reason])
            end,
            {noreply, TCPState#tcp{state = NewState}};
        _ ->
            {noreply, TCPState}
    end;

%%{ok,#{ack => <<"Hi dgiot, Xiao Ming ddd">>,
%%payload => <<"Hi dgiot, Xiao Ming ddd">>,
%%topic => <<"$dgiot/thing/dsdfsfsdfe/devaddr">>},
%%[{<<"grpc-status">>,<<"0">>}]}
do_cmd(ProductId, Cmd, Data, #tcp{state = #state{id = ChannelId}} = TCPState) ->
    case dgiot_dlink_client:payload(#{data => Data, cmd => dgiot_utils:to_binary(Cmd), product => ProductId}, #{channel => ChannelId}) of
        {ok, #{ack := Ack, topic := Topic, payload := Payload} = _Result, _} ->
%%            io:format("~s ~p Result ~p ~n",[?FILE, ?LINE, _Result]),
            case Ack of
                <<>> ->
                    pass;
                Ack ->
                    case dgiot_tcp_server:send(TCPState, Ack) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            dgiot_bridge:send_log(ChannelId, ProductId, "Send Fail, ~p, CMD:~p", [Cmd, Reason])
                    end
            end,
            case Topic of
                <<>> ->
                    pass;
                Topic ->
                    dgiot_mqtt:publish(ProductId, Topic, Payload)
            end;
        _ ->
            pass
    end,
    {noreply, TCPState}.

log_fun(ChannelId) ->
    fun(Type, Buff) ->
        Data =
            case Type of
                <<"ERROR">> ->
                    Buff;
                _ -> dgiot_utils:binary_to_hex(Buff)
            end,
        dgiot_bridge:send_log(ChannelId, "~s", [<<Type/binary, " ", Data/binary>>])
    end.

