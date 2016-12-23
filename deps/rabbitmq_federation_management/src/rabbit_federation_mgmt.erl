%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_federation_mgmt).

-behaviour(rabbit_mgmt_extension).

-export([dispatcher/0, web_ui/0]).
-export([init/3, rest_init/2, to_json/2, resource_exists/2, content_types_provided/2,
         is_authorized/2]).

-import(rabbit_misc, [pget/2]).

-include_lib("rabbitmq_management_agent/include/rabbit_mgmt_records.hrl").

dispatcher() -> [{"/federation-links",        ?MODULE, [all]},
                 {"/federation-links/:vhost", ?MODULE, [all]},
                 {"/federation-down-links",        ?MODULE, [down]},
                 {"/federation-down-links/:vhost", ?MODULE, [down]}].

web_ui()     -> [{javascript, <<"federation.js">>}].

%%--------------------------------------------------------------------

init(_, _, _) ->
    {upgrade, protocol, cowboy_rest}.

rest_init(Req, [Filter]) ->
    {ok, Req, {Filter, #context{}}}.

content_types_provided(ReqData, Context) ->
   {[{<<"application/json">>, to_json}], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {case rabbit_mgmt_util:vhost(ReqData) of
         not_found -> false;
         _         -> true
     end, ReqData, Context}.

to_json(ReqData, {Filter, Context}) ->
    Chs = rabbit_mgmt_db:get_all_channels(
            rabbit_mgmt_util:range(ReqData)),
    rabbit_mgmt_util:reply_list(
      filter_vhost(status(Chs, ReqData, Context, Filter), ReqData), ReqData, Context).

is_authorized(ReqData, {Filter, Context}) ->
    {Res, RD, C} = rabbit_mgmt_util:is_authorized_monitor(ReqData, Context),
    {Res, RD, {Filter, C}}.

%%--------------------------------------------------------------------

filter_vhost(List, ReqData) ->
    rabbit_mgmt_util:all_or_one_vhost(
      ReqData,
      fun(V) -> lists:filter(fun(I) -> pget(vhost, I) =:= V end, List) end).

status(Chs, ReqData, Context, Filter) ->
    rabbit_mgmt_util:filter_vhost(
      lists:append([status(Node, Chs, Filter) || Node <- [node() | nodes()]]),
      ReqData, Context).

status(Node, Chs, Filter) ->
    case rpc:call(Node, rabbit_federation_status, status, [], infinity) of
        {badrpc, {'EXIT', {undef, _}}}  -> [];
        {badrpc, {'EXIT', {noproc, _}}} -> [];
        Status                          -> [format(Node, I, Chs) || I <- Status,
                                                                    filter_status(I, Filter)]
    end.

filter_status(_, all) ->
    true;
filter_status(Props, down) ->
    Status = pget(status, Props),
    not lists:member(Status, [running, starting]).

format(Node, Info, Chs) ->
    LocalCh = case rabbit_mgmt_format:strip_pids(
                     [Ch || Ch <- Chs,
                            pget(name, pget(connection_details, Ch))
                                =:= pget(local_connection, Info)]) of
                  [Ch] -> [{local_channel, Ch}];
                  []   -> []
              end,
    [{node, Node} | format_info(Info)] ++ LocalCh.

format_info(Items) ->
    [format_item(I) || I <- Items].

format_item({timestamp, {{Y, M, D}, {H, Min, S}}}) ->
    {timestamp, print("~w-~2.2.0w-~2.2.0w ~w:~2.2.0w:~2.2.0w",
                      [Y, M, D, H, Min, S])};
format_item({error, E}) ->
    {error, rabbit_mgmt_format:print("~p", [E])};
format_item(I) ->
    I.

print(Fmt, Val) ->
    list_to_binary(io_lib:format(Fmt, Val)).
