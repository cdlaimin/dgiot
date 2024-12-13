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

-module(dgiot_parse_handler).
-author("dgiot").
-include_lib("dgiot/include/logger.hrl").
-behavior(dgiot_rest).
-dgiot_rest(all).

%% API
-export([swagger_parse/0]).
-export([handle/4]).

%% API描述
%% 支持二种方式导入
%% 示例:
%% 1. Metadata为map表示的JSON,
%%    dgiot_http_server:bind(<<"/iotapi">>, ?MODULE, [], Metadata)
%% 2. 从模块的priv/swagger/下导入
%%    dgiot_http_server:bind(<<"/swagger_parse.json">>, ?MODULE, [], priv)
swagger_parse() ->
    [
        dgiot_http_server:bind(<<"/swagger_parse.json">>, ?MODULE, [], priv)
    ].


%%%===================================================================
%%% 请求处理
%%%  如果登录, Context 内有 <<"user">>, version
%%%===================================================================

-spec handle(OperationID :: atom(), Args :: map(), Context :: map(), Req :: dgiot_req:req()) ->
    {Status :: dgiot_req:http_status(), Body :: map()} |
    {Status :: dgiot_req:http_status(), Headers :: map(), Body :: map()} |
    {Status :: dgiot_req:http_status(), Headers :: map(), Body :: map(), Req :: dgiot_req:req()}.

handle(OperationID, Args, Context, Req) ->
    Headers = #{},
    case catch do_request(OperationID, Args, Context, Req) of
        {ErrType, Reason} when ErrType == 'EXIT'; ErrType == error ->
            ?LOG(debug, "do request: ~p, ~p, ~p~n", [OperationID, Args, Reason]),
            Err = case is_binary(Reason) of
                      true -> Reason;
                      false -> list_to_binary(io_lib:format("~p", [Reason]))
                  end,
            {500, Headers, #{<<"error">> => Err}};
        ok ->
            ?LOG(debug, "do request: ~p, ~p ->ok ~n", [OperationID, Args]),
            {200, Headers, #{}, Req};
        {ok, Res} ->
            ?LOG(debug, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {200, Headers, Res, Req};
        {Status, Res} ->
            ?LOG(debug, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {Status, Headers, Res, Req};
        {Status, NewHeaders, Res} ->
            ?LOG(debug, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {Status, maps:merge(Headers, NewHeaders), Res, Req};
        {Status, NewHeaders, Res, NewReq} ->
            ?LOG(debug, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {Status, maps:merge(Headers, NewHeaders), Res, NewReq}
    end.


%%%===================================================================
%%% 内部函数 Version:API版本
%%%===================================================================
%% Role模版 概要: 导库 描述:json文件导库
%% OperationId:post_role
%% 请求:POST /iotapi/role
do_request(post_graphql, Body, #{<<"sessionToken">> := SessionToken} = _Context, _Req0) ->
    case dgiot_parse_graphql:graphql(Body#{<<"access_token">> => SessionToken}) of
        {ok, Result} ->
            {200, Result};
        Other -> Other
    end;

%% Product 概要: 导库 描述:json文件导库
%% OperationId:post_tree
%% 请求:POST /iotapi/post_tree
do_request(post_tree, #{<<"class">> := Class, <<"parent">> := Parent, <<"filter">> := Filter}, #{<<"sessionToken">> := SessionToken} = _Context, _Req0) ->
    dgiot_parse_utils:get_classtree(Class, Parent, jsx:decode(Filter, [{labels, binary}, return_maps]), SessionToken);

do_request(post_batch, #{<<"requests">> := Requests}, _Context, _Req) ->
    case dgiot_parse:batch(Requests) of
        {ok, Result} -> {200, Result};
        {error, Reason} -> {400, Reason}
    end;

do_request(get_health, _Body, _Context, _Req) ->
    {ok, #{<<"msg">> => <<"success">>}};

%% 数据库升级
do_request(get_upgrade, _Body, _Context, Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    SessionToken = proplists:get_value(<<"departmentToken">>, Cookies),
%%    io:format("~s ~p SessionToken = ~p.~n", [?FILE, ?LINE, SessionToken]),
    dgiot_parse_utils:update(SessionToken);

%%%% 版本升级
do_request(post_upgrade, _Body, _Context, Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    SessionToken = proplists:get_value(<<"departmentToken">>, Cookies),
%%    io:format("~s ~p SessionToken = ~p.~n", [?FILE, ?LINE, SessionToken]),
    dgiot_parse_utils:update(SessionToken);

%%  服务器不支持的API接口
do_request(_OperationId, _Args, _Context, _Req) ->
    {error, <<"Not Allowed.">>}.
