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

-module(dgiot_udp_client).
-author("johnliu").
-include("dgiot_socket.hrl").
-include_lib("dgiot/include/logger.hrl").
-include_lib("dgiot/include/dgiot_client.hrl").

-behaviour(gen_server).
%% API
-export([start_link/1, send/2, send/3, do_connect/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(connect_state, {host, port, mod, socket = undefined, transport, freq = 30, count = 1000, child, reconnect_times = 3, reconnect_sleep = 30}).

-define(TIMEOUT, 10000).
-define(UDP_OPTIONS, [binary, {active, once}, {packet, raw}, {reuseaddr, true}, {send_timeout, ?TIMEOUT}]).
%%-define(UDP_OPTIONS, [binary, {reuseaddr, true}]).

start_link(Args) ->
    dgiot_client:start_link(?MODULE, Args).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([#{<<"channel">> := ChannelId, <<"client">> := ClientId, <<"ip">> := Host, <<"port">> := Port, <<"mod">> := Mod} = Args]) ->
    Transport = gen_udp,
    Ip = dgiot_utils:to_list(Host),
    Port1 = dgiot_utils:to_int(Port),
    UserData = #connect_state{mod = Mod, host = Ip, port = Port1, freq = 30, count = 300, transport = Transport},
    ChildState = maps:get(<<"child">>, Args, #{}),
    StartTime = dgiot_client:get_time(maps:get(<<"starttime">>, Args, dgiot_datetime:now_secs())),
    EndTime = dgiot_client:get_time(maps:get(<<"endtime">>, Args, dgiot_datetime:now_secs() + 1000000000)),
    Freq = maps:get(<<"freq">>, Args, 30),
    NextTime = dgiot_client:get_nexttime(StartTime, Freq),
    Count = dgiot_client:get_count(StartTime, EndTime, Freq),
    Rand =
        case maps:get(<<"rand">>, Args, true) of
            true -> 0;
            _ -> dgiot_client:get_rand(Freq)
        end,
    Clock = #dclock{freq = Freq, nexttime = NextTime + Rand, count = Count, round = 0},
    Dclient = #dclient{channel = ChannelId, client = ClientId, status = ?DCLIENT_INTIALIZED, clock = Clock, userdata = UserData, child = ChildState},
    dgiot_client:add(ChannelId, ClientId),
    case Mod:init(Dclient) of
        {ok, NewDclient} ->
            do_connect(false, NewDclient),
            {ok, NewDclient, hibernate};
        {stop, Reason} ->
            {stop, Reason}
    end.

handle_call({connection_ready, Socket}, _From, #dclient{channel = ChannelId, client = ClientId, userdata = #connect_state{mod = Mod} = UserData} = Dclient) ->
    NewUserData = UserData#connect_state{socket = Socket},
    case Mod:handle_info(connection_ready, Dclient#dclient{userdata = NewUserData}) of
        {noreply, NewDclient} ->
            {reply, ok, NewDclient, hibernate};
        {stop, _Reason, NewDclient} ->
            dgiot_client:stop(ChannelId, ClientId),
            {reply, _Reason, NewDclient}
    end;

handle_call(Request, From, #dclient{channel = ChannelId, client = ClientId,
    userdata = #connect_state{mod = Mod}} = Dclient) ->
    case Mod:handle_call(Request, From, Dclient) of
        {reply, Reply, NewDclient} ->
            {reply, Reply, NewDclient, hibernate};
        {stop, Reason, NewDclient} ->
            dgiot_client:stop(ChannelId, ClientId),
            {reply, Reason, NewDclient}
    end.

handle_cast(Msg, #dclient{channel = ChannelId, client = ClientId,
    userdata = #connect_state{mod = Mod}} = Dclient) ->
    case Mod:handle_cast(Msg, Dclient) of
        {noreply, NewDclient} ->
            {noreply, NewDclient, hibernate};
        {stop, Reason, NewDclient} ->
            dgiot_client:stop(ChannelId, ClientId),
            {reply, Reason, NewDclient}
    end.

%% 连接次数为0了
handle_info(do_connect, Dclient) ->
%%    ?LOG(info, "do_connect ~s:~p", [State#connect_state.host, State#connect_state.port]),
    {stop, normal, Dclient};

%% 连接次数为0了
handle_info(connect_stop, Dclient) ->
%%    ?LOG(info, "CONNECT CLOSE ~s:~p", [State#connect_state.host, State#connect_state.port]),
    {noreply, Dclient, hibernate};

handle_info({connection_ready, Socket}, #dclient{userdata = #connect_state{mod = Mod} = UserData} = Dclient) ->
%%    io:format("~s ~p connection_ready ~p ~n", [?FILE, ?LINE, Dclient]),
    NewUserData = UserData#connect_state{socket = Socket},
    case Mod:handle_info(connection_ready, Dclient#dclient{userdata = NewUserData}) of
        {noreply, NewDclient} ->
            inet:setopts(Socket, [{active, once}]),
            {noreply, NewDclient, hibernate};
        {stop, Reason, NewDclient} ->
            {stop, Reason, NewDclient}
    end;

%% 往udp server 发送报文
handle_info({send, _PayLoad}, #dclient{userdata = #connect_state{socket = undefined}} = Dclient) ->
    {noreply, Dclient, hibernate};
handle_info({send, PayLoad}, #dclient{userdata = #connect_state{host = _Ip, port = _Port, transport = Transport, socket = Socket}} = Dclient) ->
%%    io:format("~s ~p ~p send to from ~p:~p : ~p ~n", [?FILE, ?LINE, self(), _Ip, _Port, dgiot_utils:to_hex(PayLoad)]),
    Transport:send(Socket, PayLoad),
    {noreply, Dclient, hibernate};

handle_info({ssl, _RawSock, Data}, Dclient) ->
    handle_info({ssl, _RawSock, Data}, Dclient);

handle_info({udp, Socket, _Ip, _Port, Binary} = _A, #dclient{userdata = #connect_state{socket = Socket, mod = Mod}} = Dclient) ->
    NewBin =
        case binary:referenced_byte_size(Binary) of
            Large when Large > 2 * byte_size(Binary) ->
                binary:copy(Binary);
            _ ->
                Binary
        end,
    case Mod:handle_info({udp, NewBin}, Dclient) of
        {noreply, NewDclient} ->
            inet:setopts(Socket, [{active, once}]),
            {noreply, NewDclient, hibernate};
        {stop, Reason, NewDclient} ->
            {noreply, Reason, NewDclient, hibernate}
    end;

handle_info({udp_error, _Socket, _Reason}, Dclient) ->
    {noreply, Dclient, hibernate};

handle_info({udp_closed, _Sock}, #dclient{channel = ChannelId, client = ClientId,
    userdata = #connect_state{transport = Transport, socket = Socket, mod = Mod}} = Dclient) ->
    Transport:close(Socket),
    case Mod:handle_info(udp_closed, Dclient) of
        {noreply, #dclient{userdata = Userdata} = NewDclient} ->
            NewDclient1 = NewDclient#dclient{userdata = Userdata#connect_state{socket = undefined}},
            case is_integer(Userdata#connect_state.reconnect_sleep) of
                false ->
                    dgiot_client:stop(ChannelId, ClientId),
                    {noreply, NewDclient, hibernate};
                true ->
                    Now = erlang:system_time(second),
                    Sleep =
                        case get(last_closed) of
                            Time when is_integer(Time) andalso Now - Time < Userdata#connect_state.reconnect_sleep ->
                                true;
                            _ ->
                                false
                        end,
                    put(last_closed, Now),
                    {noreply, do_connect(Sleep, NewDclient1), hibernate}
            end;
        {stop, _Reason, NewDclient} ->
            dgiot_client:stop(ChannelId, ClientId),
            {noreply, NewDclient, hibernate}
    end;

handle_info(Info, #dclient{channel = ChannelId, client = ClientId, userdata = #connect_state{mod = Mod, transport = Transport, socket = Socket}} = Dclient) ->
%%    io:format("~s ~p Info ~p ~n", [?FILE, ?LINE, Info]),
%%    io:format("~s ~p Dclient ~p ~n", [?FILE, ?LINE, Dclient]),
    case Mod:handle_info(Info, Dclient) of
        {noreply, NewDclient} ->
            {noreply, NewDclient, hibernate};
        {stop, _Reason, NewDclient} ->
            Transport:close(Socket),
            timer:sleep(10),
            dgiot_client:stop(ChannelId, ClientId),
            {noreply, NewDclient, hibernate}
    end.

terminate(Reason, #connect_state{mod = Mod, child = ChildState}) ->
    Mod:terminate(Reason, ChildState).

code_change(OldVsn, #connect_state{mod = Mod, child = ChildState} = State, Extra) ->
    {ok, NewChildState} = Mod:code_change(OldVsn, ChildState, Extra),
    {ok, State#connect_state{child = NewChildState}}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
send(#udp{transport = Transport, socket = Socket, log = _Log}, Payload) ->
    case Socket == undefined of
        true ->
            {error, disconnected};
        false ->
            timer:sleep(1),
            Transport:send(Socket, Payload)
    end.

send(ChannelId, ClientId, Payload) ->
    case dgiot_client:get(ChannelId, ClientId) of
        {ok, Pid} ->
            Pid ! {send, Payload};
        _ ->
            pass
    end.

do_connect(Sleep, #dclient{userdata = Connect_state} = State) ->
    Client = self(),
    spawn(
        fun() ->
            Sleep andalso timer:sleep(Connect_state#connect_state.reconnect_sleep * 1000),
            connect(Client, State)
        end),
    State.

connect(Client, #dclient{userdata = #connect_state{host = Host, port = Port, reconnect_times = Times, reconnect_sleep = Sleep} = Connect_state} = State) ->
%%    io:format("~s ~p Client ~s:~p ~p", [?FILE, ?LINE, Host, Port, Client]),
    case is_process_alive(Client) of
        true ->
%%            ?LOG(info, "CONNECT ~s:~p ~p", [Host, Port, Times]),
%%            io:format("~s ~p CONNECT ~s:~p ~p", [?FILE, ?LINE, Host, Port, Times]),
            case gen_udp:open(0, [binary, {reuseaddr, true}]) of
                {ok, Socket} ->
                    %% Trigger the udp_passive event
                    case gen_udp:connect(Socket, dgiot_utils:to_list(Host), Port) of
                        ok ->
                            case catch gen_server:call(Client, {connection_ready, Socket}, 5000) of
                                ok ->
                                    inet:setopts(Socket, [{active, once}]),
                                    gen_udp:controlling_process(Socket, Client);
                                _ ->
                                    ok
                            end;
                        {error, Reason} ->
                            case is_integer(Times) of
                                true when Times - 1 > 0 ->
                                    Client ! {connection_error, Reason},
                                    timer:sleep(Sleep * 1000),
                                    connect(Client, State#dclient{userdata = Connect_state#connect_state{reconnect_times = Times - 1}});
                                false when is_atom(Times) ->
                                    Client ! {connection_error, Reason},
                                    timer:sleep(Sleep * 1000),
                                    connect(Client, State);
                                _ ->
                                    Client ! connect_stop
                            end
                    end;
                _ ->
                    pass
            end
    end.
