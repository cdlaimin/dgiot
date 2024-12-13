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

-module(dgiot_grpc_client).

-export([create_channel_pool/1, create_channel_pool/3, stop_channel_pool/1, send/2]).

create_channel_pool(ClinetId) ->
    create_channel_pool(ClinetId, "http://127.0.0.1:30051", 1).

create_channel_pool(ClinetId, SvrAddr, PoolSize) ->
    {ok, _} = grpc_client_sup:create_channel_pool(ClinetId, dgiot_utils:to_list(SvrAddr), #{pool_size => PoolSize}).

stop_channel_pool(ClinetId) ->
    _ = grpc_client_sup:stop_channel_pool(ClinetId).

send(ClinetId, Request) ->
    case dgiot_dlink_client:payload(Request, #{channel => ClinetId}) of
        {ok, #{ack := ReMessage}, _} ->
            {ok, ReMessage};
        _ ->
            #{}
    end.
