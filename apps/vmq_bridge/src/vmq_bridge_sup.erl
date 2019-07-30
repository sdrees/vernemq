%% Copyright 2018 Erlio GmbH Basel Switzerland (http://erl.io)
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

-module(vmq_bridge_sup).

-behaviour(supervisor).
-behaviour(on_config_change_hook).

%% API
-export([start_link/0,
         bridge_info/0,
         metrics/0]).
-export([change_config/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(Id, Mod, Type, Args), {Id, {Mod, start_link, Args}, permanent, 5000, Type, [Mod]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


bridge_info() ->
    lists:map(
      fun({{_, Host, Port}, Pid, _, _}) ->
              case vmq_bridge:info(Pid) of
                  {error, not_started} ->
                      #{host => Host,
                        port => Port,
                        out_buffer_size => $-,
                        out_buffer_max_size => $-,
                        out_buffer_dropped => $-
                       };
                  {ok, #{out_queue_size := Size,
                         out_queue_max_size := Max,
                         out_queue_dropped := Dropped}} ->
                      #{host => Host,
                        port => Port,
                        out_buffer_size => Size,
                        out_buffer_max_size => Max,
                        out_buffer_dropped => Dropped
                       }
              end
      end,
      supervisor:which_children(vmq_bridge_sup)).
%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
change_config(Configs) ->
    case lists:keyfind(vmq_bridge, 1, application:which_applications()) of
        false ->
            %% vmq_bridge app is loaded but not started
            ok;
        _ ->
            %% vmq_bridge app is started
            {vmq_bridge, BridgeConfig} = lists:keyfind(vmq_bridge, 1, Configs),
            {TCP, SSL} = proplists:get_value(config, BridgeConfig, {[], []}),
            Bridges = supervisor:which_children(?MODULE),
            reconfigure_bridges(tcp, Bridges, TCP),
            reconfigure_bridges(ssl, Bridges, SSL),
            stop_and_delete_unused(Bridges, lists:flatten([TCP, SSL]))
    end.

reconfigure_bridges(Type, Bridges, [{HostString, Opts}|Rest]) ->
    {Host,PortString} = list_to_tuple(string:tokens(HostString, ":")),
    {Port,_}=string:to_integer(PortString),
    Ref = ref(Host, Port),
    case lists:keyfind(Ref, 1, Bridges) of
        false ->
            start_bridge(Type, Ref, Host, Port, Opts);
        {_, Pid, _, _} when is_pid(Pid) -> % change existing bridge
            %% restart the bridge
            ok = stop_bridge(Ref),
            start_bridge(Type, Ref, Host, Port, Opts);
        _ ->
            ok
    end,
    reconfigure_bridges(Type, Bridges, Rest);
reconfigure_bridges(_, _, []) -> ok.

start_bridge(Type, Ref, Host, Port, Opts) ->
    {ok, RegistryMFA} = application:get_env(vmq_bridge, registry_mfa),
    ChildSpec = {Ref,
                 {vmq_bridge, start_link, [Type, Host, Port, RegistryMFA, Opts]},
                 permanent, 5000, worker, [vmq_bridge]},
    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

stop_and_delete_unused(Bridges, Config) ->
    BridgesToDelete =
    lists:foldl(fun({HostString, _}, Acc) ->
                        {Host,PortString} = list_to_tuple(string:tokens(HostString, ":")),
                        {Port,_}=string:to_integer(PortString),
                        Ref = ref(Host, Port),
                        lists:keydelete(Ref, 1, Acc)
                end, Bridges, Config),
    lists:foreach(fun({Ref, _, _, _}) ->
                          stop_bridge(Ref)
                  end, BridgesToDelete).

stop_bridge(Ref) ->
    ets:delete(vmq_bridge_meta, Ref),
    supervisor:terminate_child(?MODULE, Ref),
    supervisor:delete_child(?MODULE, Ref).

ref(Host, Port) ->
    {vmq_bridge, Host, Port}.

init([]) ->
    vmq_bridge_meta = ets:new(vmq_bridge_meta, [named_table,set,public]),
    {ok, { {one_for_one, 5, 10}, []}}.

metrics() ->
    ets:foldl(
      fun({ClientPid},Acc) ->
              case gen_mqtt_client:stats(ClientPid) of
                  undefined ->
                      ets:delete(vmq_bridge_meta, ClientPid),
                      Acc;
                  #{dropped := Dropped} ->
                      [{counter, [], {vmq_bridge_queue_drop, ClientPid}, vmq_bridge_dropped_msgs, "The number of dropped messages (queue full)", Dropped}|Acc]
              end
      end, [], vmq_bridge_meta).
