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

-module(dgiot_parse_rest).
-compile(nowarn_deprecated_function).
-author("kenneth").
-include("dgiot_parse.hrl").
-include_lib("dgiot/include/logger.hrl").
-define(JSON_DECODE(Data), jsx:decode(Data, [{labels, binary}, return_maps])).
-define(HTTPOption(Option), [{timeout, 60000}, {connect_timeout, 60000}] ++ Option).
-define(REQUESTOption(Option), [{body_format, binary} | Option]).
-define(HEAD_CFG, [{"content-length", del}, {"referer", del}, {"user-agent", "dgiot"}]).


%% API
-export([request/5, method/1, method/2, check_view/2]).

%%%===================================================================
%%% API
%%%===================================================================

method(Method) ->
    list_to_atom(string:to_lower(to_list(Method))).
method(Method, atom) ->
    list_to_atom(string:to_lower(to_list(Method)));
method(Method, binary) ->
    list_to_binary(string:to_lower(to_list(Method))).

request(Method, Header, Path0, Body, Options) when is_binary(Method) ->
    NewMethod = list_to_atom(string:to_upper(binary_to_list(Method))),
    request(NewMethod, Header, Path0, Body, Options);

request(Method, Header, Path0, Body, Options) ->
    {IsGetCount, Path, NewBody} = get_request_args(Path0, Method, Body, Header, Options),
    dgiot_parse_git:commit(to_binary(Path), Method, Body),
    Header1 = dgiot_parse:get_header_token(Path, Header),
    NewHeads = get_headers(Method, Path, Header1, Options),
    Fun =
        fun() ->
            NewBody1 =
                case IsGetCount of
                    true ->
                        encode_body(Path, Method, NewBody, Options);
                    false ->
                        NewBody
                end,
            case Method of
                _ when Method == 'GET'; Method == 'DELETE' ->
                    {NewPath, Query} =
                        case re:split(Path, <<"\\?">>, [{return, binary}]) of
                            [Path1] when NewBody1 =/= <<>> ->
                                {Path1, <<"?", NewBody1/binary>>};
                            [Path1, Query0] when NewBody1 =/= <<>> ->
                                {Path1, <<"?", Query0/binary, "&", NewBody1/binary>>};
                            _ ->
                                {to_binary(Path), <<>>}
                        end,
                    do_request(Method, NewPath, NewHeads, Query, Options);
                _ when Method == 'POST'; Method == 'PUT' ->
                    do_request(Method, to_binary(Path), NewHeads, NewBody1, Options)
            end
        end,
    case IsGetCount of
        true ->
            get_count(Method, to_binary(Path), NewHeads, NewBody, Options, Fun);
        false ->
            handle_result(Fun())
    end.


%%%===================================================================
%%% Internal functions
%%%===================================================================
get_count(Method, Path, Header, Body, Options, Fun) ->
    QueryData = Body#{<<"count">> => <<"objectId">>, <<"keys">> => [<<"objectId">>], <<"limit">> => 1},
    NewBody = maps:with([<<"where">>, <<"count">>, <<"limit">>, <<"keys">>], QueryData),
    NewBody1 = encode_body(Path, Method, NewBody, Options),
    {NewPath, Query} =
        case re:split(Path, <<"\\?">>, [{return, binary}]) of
            [Path1] when NewBody1 =/= <<>> ->
                {Path1, <<"?", NewBody1/binary>>};
            [Path1, Query0] when NewBody1 =/= <<>> ->
                {Path1, <<"?", Query0/binary, "&", NewBody1/binary>>};
            _ ->
                {to_binary(Path), <<>>}
        end,
    case httpc_request(Method, NewPath, Header, Query, [], [], Options) of
        {ok, 200, _, CountBody} ->
            case jsx:is_json(CountBody) of
                #{<<"count">> := Count} ->
                    handle_result(Fun(), #{<<"count">> => Count});
                _ ->
                    handle_result(Fun(), #{})
            end;
        _Other ->
            handle_result(Fun(), #{})
    end.

to_list(V) when is_atom(V) -> atom_to_list(V);
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) when is_integer(V) -> integer_to_list(V);
to_list(V) when is_list(V) -> V;
to_list(V) -> io_lib:format("~p", [V]).

to_binary(V) when is_atom(V) -> to_binary(atom_to_list(V));
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) when is_binary(V) -> V;
to_binary(V) -> to_binary(io_lib:format("~p", [V])).

get_newwhere(Header, Where) ->
    case jsx:is_json(Where) of
        true ->
            SessionToken = proplists:get_value(<<"sessiontoken">>, Header),
            Map = dgiot_json:decode(Where),
            case dgiot_auth:get_session(SessionToken) of
                #{<<"roles">> := Roles} ->
                    RoleIds =
                        maps:fold(fun(RoleId, Role, Acc) ->
                            case maps:find(<<"level">>, Role) of
                                {ok, Level} when Level < 3 ->
                                    Acc ++ [true];
                                _ ->
                                    Acc ++ [RoleId]
                            end
                                  end, [], Roles),
                    case lists:member(true, RoleIds) of
                        true ->
                            Where;
                        _ ->
                            dgiot_json:encode(Map#{<<"$relatedTo">> => #{
                                <<"object">> =>
                                #{<<"__type">> => <<"Pointer">>,
                                    <<"className">> => <<"_Role">>,
                                    <<"objectId">> => #{<<"$in">> => RoleIds}},
                                <<"key">> => <<"views">>
                            }})
                    end;
                _ ->
                    Where
            end;
        _ ->
            Where
    end.

get_request_args(<<"/classes/View", _/binary>> = Path, Method, <<>>, Header, Options) ->
    {NewPath, Query} = get_query(Path),
    NewQuery =
        case maps:find(<<"where">>, Query) of
            {ok, Where} ->
                Query#{<<"where">> => get_newwhere(Header, Where)};
            _ ->
                Query
        end,
    get_body(NewPath, Method, NewQuery, Header, Options);

get_request_args(Path, Method, <<>>, Header, Options) ->
    {NewPath, Query} = get_query(Path),
    get_body(NewPath, Method, Query, Header, Options);

get_request_args(Path, Method, Body, Header, Options) when is_binary(Body) ->
    case catch ?JSON_DECODE(Body) of
        Map when is_map(Map) ->
            get_request_args(Path, Method, Map, Header, Options);
        _ ->
            {false, Path, Body}
    end;

get_request_args(Path, Method, Body, Header, Options) ->
%%    io:format("~s ~p Path ~p Method ~p Body ~p ~n",[?FILE, ?LINE, Path, Method, Body]),
    get_body(Path, Method, Body, Header, Options).


get_headers(Method, Path, Header, Options) when is_list(Header) ->
    get_headers(Method, Path, maps:from_list(Header), Options);
get_headers(Method, Path, Header, Options) ->
    #{
        <<"appid">> := AppId,
        <<"restkey">> := RestKey,
        <<"master">> := MasterKey
    } = proplists:get_value(cfg, Options),
    NewHeader = maps:fold(
        fun(Key, Value, Acc) ->
            NewKey = to_list(Key),
            case proplists:get_value(string:to_lower(NewKey), ?HEAD_CFG) of
                del -> Acc;
                undefined -> [{NewKey, to_list(Value)} | Acc];
                NewValue -> [{NewKey, to_list(NewValue)} | Acc]
            end
        end, [], Header),
    case proplists:get_value(from, Options, js) of
        js ->
            NewHeader;
        rest ->
            NewHeader1 =
                case Path of
                    <<"/users">> when Method == 'POST' -> % 注册
                        [{"X-Parse-Revocable-Session", "1"}, {"X-Parse-REST-API-Key", to_list(RestKey)} | NewHeader];
                    <<"/login?", _/binary>> when Method == 'GET' -> % 登录
                        [{"X-Parse-Revocable-Session", "1"}, {"X-Parse-REST-API-Key", to_list(RestKey)} | NewHeader];
                    <<"/classes/View", _/binary>> when Method == 'GET' -> % view
                        [{"X-Parse-Master-Key", to_list(MasterKey)} | NewHeader];
                    _ ->
                        [{"X-Parse-REST-API-Key", to_list(RestKey)} | NewHeader]
                end,
            lists:flatten([
                {"X-Parse-Application-Id", to_list(AppId)},
                NewHeader1
            ]);
        master ->
            lists:flatten([
                {"X-Parse-Application-Id", to_list(AppId)},
                {"X-Parse-Master-Key", to_list(MasterKey)},
                NewHeader
            ])
    end.


get_query(Path) ->
    case re:split(Path, <<"\\?">>, [{return, binary}]) of
        [NewPath, Query] ->
            case re:run(Query, <<"([^?=&]*)=([^&]*)">>, [{capture, all, binary}, global]) of
                {match, Match} ->
                    Querys = lists:foldl(
                        fun([_All, Key, Value0], Acc) ->
                            Value = iolist_to_binary(http_uri:decode(binary_to_list(Value0))),
                            Acc#{
                                Key => iolist_to_binary(http_uri:decode(binary_to_list(Value)))
                            }
                        end, #{}, Match),
                    {NewPath, Querys};
                _ ->
                    {Path, #{}}
            end;
        _ ->
            {Path, #{}}
    end.

get_body(Path, Method, Map, _Header, Options) ->
    #{<<"appid">> := AppId, <<"jskey">> := JsKey} = proplists:get_value(cfg, Options),
    {IsGetCount, Columns} =
        case maps:get(<<"keys">>, Map, false) of
            false -> {false, []};
            Keys ->
                NewKeys =
                    case Keys of
                        KeysBin when is_binary(KeysBin) ->
                            re:split(KeysBin, <<",">>, [{return, binary}]);
                        KeysList when is_list(KeysList) ->
                            KeysList
                    end,
                case lists:member(<<"count(*)">>, NewKeys) of
                    false -> {false, NewKeys};
                    true -> {true, lists:delete(<<"count(*)">>, NewKeys)}
                end
        end,
    NewMap =
        case length(Columns) == 0 of
            true -> maps:without([<<"keys">>], Map);
            false -> Map#{<<"keys">> => to_binary(list_join(Columns, ","))}
        end,
    NewMap1 =
        case proplists:get_value(from, Options, js) of
            js ->
                NewMap0 =
                    case Path of
                        <<"/users">> when Method == 'POST' -> % 注册
                            maps:without([<<"_SessionToken">>], NewMap);
                        <<"/login">> when Method == 'POST' -> % 登录
                            maps:without([<<"_SessionToken">>], NewMap);
                        _ ->
                            NewMap
                    end,
                NewMap0#{
                    <<"_JavaScriptKey">> => to_binary(JsKey),
                    <<"_ApplicationId">> => to_binary(AppId)
                };
            Type when Type == master; Type == rest ->
                NewMap
        end,
    case IsGetCount of
        true ->
            {true, Path, NewMap1};
        false ->
            {false, Path, encode_body(Path, Method, NewMap1, Options)}
    end.

encode_body(<<"/batch">>, 'POST', #{<<"requests">> := Requests}, Options) ->
    #{<<"path">> := RootPath} = proplists:get_value(cfg, Options),
    Fun =
        fun
            (#{<<"path">> := Path, <<"method">> := Method, <<"body">> := Body}) ->
                #{
                    <<"method">> => Method,
                    <<"body">> => Body,
                    <<"path">> => list_to_binary(dgiot_httpc:url_join([RootPath, Path]))
                };
            (#{<<"path">> := Path, <<"method">> := Method}) ->
                #{
                    <<"method">> => Method,
                    <<"path">> => list_to_binary(dgiot_httpc:url_join([RootPath, Path]))
                }
        end,
    Requests1 = [Fun(Request) || Request <- Requests],
    dgiot_json:encode(#{<<"requests">> => Requests1});

encode_body(_Path, Method, Args, _Options) when Method == 'GET'; Method == 'DELETE' ->
    NewArgs =
        maps:fold(
            fun
                (<<"where">>, Where, Acc) ->
                    Value =
                        case is_binary(Where) of
                            true ->
                                dgiot_httpc:urlencode(Where);
                            false ->
                                dgiot_httpc:urlencode(dgiot_json:encode(Where))
                        end,
                    [<<"where=", Value/binary>> | Acc];
                (Key, Value, Acc) ->
                    NewValue = dgiot_httpc:urlencode(dgiot_utils:to_binary(Value)),
                    [<<Key/binary, "=", NewValue/binary>> | Acc]
            end, [], Args),
    iolist_to_binary(list_join(NewArgs, "&"));
encode_body(_Path, _Method, Map, _) ->
    dgiot_json:encode(Map).

do_request(Method, Path, Header, QueryData, Options) ->
    NewQueryData =
        case jsx:is_json(QueryData) of
            true ->
                jsx:decode(QueryData, [{labels, binary}, return_maps]);
            false ->
                QueryData
        end,
    do_request_before(Method, Path, Header, QueryData, Options),
    case httpc_request(Method, Path, Header, QueryData, [], [], Options) of
        {error, Reason} ->
            {error, Reason};
        {ok, StatusCode, Headers, ResBody} ->
            case do_request_after(Method, Path, Header, NewQueryData, ResBody, Options) of
                {ok, NewResBody} ->
                    {ok, StatusCode, Headers, NewResBody};
                ignore ->
                    {ok, StatusCode, Headers, ResBody};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

httpc_request(Method, <<"/graphql">> = Path, Header, Body, HttpOptions, ReqOptions, Options) when Method == 'POST'; Method == 'PUT' ->
    #{<<"host">> := Host} = proplists:get_value(cfg, Options),
    Url = dgiot_httpc:url_join([Host, Path]),
    Request = {Url, Header, "application/json", Body},
    httpc_request(Method, Request, HttpOptions, ReqOptions);

httpc_request(Method, Path, Header, Query, HttpOptions, ReqOptions, Options) when Method == 'GET'; Method == 'DELETE' ->
    %%    ?LOG(error,"Options ~p",[Options]),
    #{<<"host">> := Host, <<"path">> := ParsePath} = proplists:get_value(cfg, Options),
    Url = dgiot_httpc:url_join([Host, ParsePath] ++ [<<Path/binary, Query/binary>>]),
    %%    io:format("~s ~p ~p ~n", [?FILE, ?LINE, Url]),
    Request = {Url, Header},
    httpc_request(Method, Request, HttpOptions, ReqOptions);

httpc_request(Method, Path, Header, Body, HttpOptions, ReqOptions, Options) when Method == 'POST'; Method == 'PUT' ->
    #{<<"host">> := Host, <<"path">> := ParsePath} = proplists:get_value(cfg, Options),
    Url = dgiot_httpc:url_join([Host, ParsePath, Path]),
    Request = {Url, Header, "application/json", Body},
    httpc_request(Method, Request, HttpOptions, ReqOptions).

httpc_request(Method, Request, HttpOptions, ReqOptions) ->
    dgiot_parse_log:log(Method, Request),
    case catch httpc:request(method(Method), Request, ?HTTPOption(HttpOptions), ?REQUESTOption(ReqOptions)) of
        {ok, {{_HTTPVersion, StatusCode, _ReasonPhrase}, Headers, Body}} ->
            {ok, StatusCode, Headers, Body};
        {error, {failed_connect, _}} ->
            {error, <<"disconnect">>};
        {'EXIT', {noproc, {gen_server, call, [httpc_manager | _]}}} ->
            {error, <<"httpc not start">>};
        {Err, Reason} when Err == error; Err == 'EXIT' ->
            {error, Reason}
    end.

do_request_before(Method0, Path, Header, QueryData, Options) ->
    Method =
        case proplists:get_value(from, Options) of
            js when QueryData == <<>> ->
                method(Method0, atom);
            js ->
                case maps:get(<<"_method">>, ?JSON_DECODE(QueryData), no) of
                    no -> method(Method0, atom);
                    Method1 -> method(Method1, atom)
                end;
            _ ->
                method(Method0, atom)
        end,
    {match, PathList} = re:run(Path, <<"([^/]+)">>, [global, {capture, all_but_first, binary}]),
    dgiot_parse_hook:do_request_hook('before', lists:concat(PathList), Method, dgiot_parse:get_token(Header), QueryData, Options).

do_request_after(Method0, Path, Header, NewQueryData, ResBody, Options) ->
    Method =
        case proplists:get_value(from, Options) of
            js when NewQueryData == <<>> ->
                method(Method0, atom);
            js ->
                case maps:get(<<"_method">>, ?JSON_DECODE(NewQueryData), no) of
                    no -> method(Method0, atom);
                    Method1 -> method(Method1, atom)
                end;
            _ ->
                method(Method0, atom)
        end,
    {match, PathList} = re:run(Path, <<"([^/]+)">>, [global, {capture, all_but_first, binary}]),
    %% io:format("~s ~p ~p ~p ~n",[?FILE, ?LINE, Path, NewQueryData]),
    dgiot_parse_hook:do_request_hook('after', lists:concat(PathList), Method, dgiot_parse:get_token(Header), NewQueryData, ResBody).


list_join([], Sep) when is_list(Sep) -> [];
list_join([H | T], Sep) ->
    to_list(H) ++ lists:append([Sep ++ to_list(X) || X <- T]).

handle_result(Result) ->
    handle_result(Result, no).
handle_result(Result, Map) ->
    case Result of
        {ok, StatusCode, Headers, Body} ->
            case is_map(Map) of
                true ->
                    case catch ?JSON_DECODE(Body) of
                        NewMap when is_map(NewMap) ->
                            {ok, StatusCode, Headers, dgiot_json:encode(maps:merge(Map, NewMap))};
                        _ ->
                            {ok, StatusCode, Headers, Body}
                    end;
                false ->
                    {ok, StatusCode, Headers, Body}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

check_view(#{<<"X-Parse-Session-Token">> := SessionToken}, ViewId) ->
    case dgiot_auth:get_session(SessionToken) of
        #{<<"roles">> := Roles} ->
            lists:any(fun(RoleId) ->
                case dgiot_role:get_role_view(RoleId, ViewId) of
                    not_find ->
                        false;
                    _ ->
                        true
                end
                      end, maps:keys(Roles));
        _ ->
            false
    end;

check_view(_, _) ->
    false.






















