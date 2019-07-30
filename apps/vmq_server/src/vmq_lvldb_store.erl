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

-module(vmq_lvldb_store).
-include_lib("stdlib/include/ms_transform.hrl").
-include("vmq_server.hrl").
-include("vmq_lvldb_store.hrl").
-behaviour(gen_server).

%% API
-export([start_link/1,
         msg_store_write/2,
         msg_store_read/2,
         msg_store_delete/2,
         msg_store_find/2,
         get_ref/1,
         refcount/1,
         get_state/1]).

-export([msg_store_init_queue_collector/4]).

-export([parse_p_idx_val_pre/1,
         parse_p_msg_val_pre/1,
         serialize_p_idx_val_pre/1,
         serialize_p_msg_val_pre/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {ref :: undefined | eleveldb:db_ref(),
                data_root :: string(),
                open_opts = [],
                config :: config(),
                read_opts = [],
                write_opts = [],
                fold_opts = [{fill_cache, false}],
                refs = ets:new(?MODULE, [])
               }).
-type config() :: [{atom(), term()}].


-define(P_IDX_PRE, 0).
-define(P_MSG_PRE, 0).


%% Subsequent formats should always extend by adding new elements to
%% the end of the record or tuple.
-type p_msg_val_pre() :: {routing_key(), payload()}.
-record(p_idx_val, {
          ts  :: erlang:timestamp(),
          dup :: flag(),
          qos :: qos()
         }).
-type p_idx_val_pre() :: #p_idx_val{}.

%%%===================================================================
%%% API
%%%===================================================================
start_link(Id) ->
    gen_server:start_link(?MODULE, [Id], []).

msg_store_write(SubscriberId, #vmq_msg{msg_ref=MsgRef} = Msg) ->
    call(MsgRef, {write, SubscriberId, Msg}).

msg_store_delete(SubscriberId, MsgRef) ->
    call(MsgRef, {delete, SubscriberId, MsgRef}).

msg_store_read(SubscriberId, MsgRef) ->
    call(MsgRef, {read, SubscriberId, MsgRef}).


%% We differentiate between queue_init and other as queue_init must
%% not be called concurrently for the same subscriber.
msg_store_find(SubscriberId, Type) when Type =:= queue_init;
                                        Type =:= other ->
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(?MODULE, msg_store_init_queue_collector,
                                [self(), SubscriberId, Ref, Type]),
    receive
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason};
        {Pid, Ref, MsgRefs} ->
            demonitor(MRef, [flush]),
            {ok, MsgRefs}
    end.

msg_store_init_queue_collector(ParentPid, SubscriberId, Ref, queue_init) ->
    MsgRefs =
        case msg_store_init_from_tbl(init, SubscriberId) of
            [] ->
                init_from_disk(SubscriberId);
            Res ->
                Res
        end,
    ParentPid ! {self(), Ref, MsgRefs};
msg_store_init_queue_collector(ParentPid, SubscriberId, Ref, other) ->
    MsgRefs = init_from_disk(SubscriberId),
    ParentPid ! {self(), Ref, MsgRefs}.

init_from_disk(SubscriberId) ->
    TblIdxRef = make_ref(),
    Pids = vmq_lvldb_store_sup:get_bucket_pids(),
    ok = msg_store_collect(TblIdxRef, SubscriberId, Pids),
    msg_store_init_from_tbl(TblIdxRef, SubscriberId).

msg_store_init_from_tbl(Prefix, SubscriberId) ->
    MS = ets:fun2ms(
           fun({{P, S, _TS, MsgRef}}) when P =:= Prefix, S =:= SubscriberId ->
                   MsgRef
           end),
    MSDel = ets:fun2ms(
           fun({{P, S, _TS, _MsgRef}}) when P =:= Prefix, S =:= SubscriberId ->
                   true
           end),
    Table = select_table(SubscriberId),
    MsgRefs = ets:select(Table, MS),
    _Deleted = ets:select_delete(Table, MSDel),
    MsgRefs.

msg_store_collect(_Ref, _, []) -> ok;
msg_store_collect(Ref, SubscriberId, [Pid|Rest]) ->
    ok = try
             gen_server:call(Pid, {find_for_subscriber_id, Ref, SubscriberId}, infinity)
         catch
             {'EXIT', {noproc, _}} ->
                 ok
         end,
    msg_store_collect(Ref, SubscriberId, Rest).

get_ref(BucketPid) ->
    gen_server:call(BucketPid, get_ref).

refcount(MsgRef) ->
    call(MsgRef, {refcount, MsgRef}).

get_state(Pid) ->
    gen_server:call(Pid, get_state, infinity).

call(Key, Req) ->
    case vmq_lvldb_store_sup:get_bucket_pid(Key) of
        {ok, BucketPid} ->
            gen_server:call(BucketPid, Req, infinity);
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([InstanceId]) ->
    %% Initialize random seed
    rand:seed(exsplus, os:timestamp()),

    Opts = vmq_config:get_env(msg_store_opts, []),
    DataDir1 = proplists:get_value(store_dir, Opts, "data/msgstore"),
    DataDir2 = filename:join(DataDir1, integer_to_list(InstanceId)),

    %% Initialize state
    S0 = init_state(DataDir2, Opts),
    process_flag(trap_exit, true),
    case open_db(Opts, S0) of
        {ok, State} ->
            self() ! {initialize_from_storage, InstanceId},
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(get_ref, _From, #state{ref=Ref} = State) ->
    {reply, Ref, State};
handle_call({refcount, MsgRef}, _From, State) ->
    RefCount =
    case ets:lookup(State#state.refs, MsgRef) of
        [] -> 0;
        [{_, Cnt}] -> Cnt
    end,
    {reply, RefCount, State};
handle_call(get_state, _From, State) ->
    %% when called externally, the store is always initialized, so
    %% just return that here.
    {reply, initialized, State};
handle_call(Request, _From, State) ->
    {reply, handle_req(Request, State), State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({initialize_from_storage, InstanceId}, State) ->
    case setup_index(State) of
        0 -> ok;
        N ->
            lager:info("indexed ~p offline messages in msg store instance ~p",
                       [N, InstanceId])
    end,
    %% Register Bucket Instance with the Bucket Registry
    vmq_lvldb_store_sup:register_bucket_pid(InstanceId, self()),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{ref=Ref}) ->
    eleveldb:close(Ref),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
init_state(DataRoot, Config) ->
    %% Get the data root directory
    filelib:ensure_dir(filename:join(DataRoot, "msg_store_dummy")),

    %% Merge the proplist passed in from Config with any values specified by the
    %% eleveldb app level; precedence is given to the Config.
    MergedConfig = orddict:merge(fun(_K, VLocal, _VGlobal) -> VLocal end,
                                 orddict:from_list(Config), % Local
                                 orddict:from_list(application:get_all_env(eleveldb))), % Global

    %% Use a variable write buffer size in order to reduce the number
    %% of vnodes that try to kick off compaction at the same time
    %% under heavy uniform load...
    WriteBufferMin = config_value(write_buffer_size_min, MergedConfig, 30 * 1024 * 1024),
    WriteBufferMax = config_value(write_buffer_size_max, MergedConfig, 60 * 1024 * 1024),
    WriteBufferSize = WriteBufferMin + rand:uniform(1 + WriteBufferMax - WriteBufferMin),

    %% Update the write buffer size in the merged config and make sure create_if_missing is set
    %% to true
    FinalConfig = orddict:store(write_buffer_size, WriteBufferSize,
                                orddict:store(create_if_missing, true, MergedConfig)),

    %% Parse out the open/read/write options
    {OpenOpts, _BadOpenOpts} = eleveldb:validate_options(open, FinalConfig),
    {ReadOpts, _BadReadOpts} = eleveldb:validate_options(read, FinalConfig),
    {WriteOpts, _BadWriteOpts} = eleveldb:validate_options(write, FinalConfig),

    %% Use read options for folding, but FORCE fill_cache to false
    FoldOpts = lists:keystore(fill_cache, 1, ReadOpts, {fill_cache, false}),

    %% Warn if block_size is set
    SSTBS = proplists:get_value(sst_block_size, OpenOpts, false),
    BS = proplists:get_value(block_size, OpenOpts, false),
    case BS /= false andalso SSTBS == false of
        true ->
            lager:warning("eleveldb block_size has been renamed sst_block_size "
                          "and the current setting of ~p is being ignored.  "
                          "Changing sst_block_size is strongly cautioned "
                          "against unless you know what you are doing.  Remove "
                          "block_size from app.config to get rid of this "
                          "message.\n", [BS]);
        _ ->
            ok
    end,

    %% Generate a debug message with the options we'll use for each operation
    lager:debug("datadir ~s options for LevelDB: ~p\n",
                [DataRoot, [{open, OpenOpts}, {read, ReadOpts}, {write, WriteOpts}, {fold, FoldOpts}]]),
    #state { data_root = DataRoot,
             open_opts = OpenOpts,
             read_opts = ReadOpts,
             write_opts = WriteOpts,
             fold_opts = FoldOpts,
             config = FinalConfig }.

config_value(Key, Config, Default) ->
    case orddict:find(Key, Config) of
        error ->
            Default;
        {ok, Value} ->
            Value
    end.

open_db(Opts, State) ->
    RetriesLeft = proplists:get_value(open_retries, Opts, 30),
    open_db(Opts, State, max(1, RetriesLeft), undefined).

open_db(_Opts, _State0, 0, LastError) ->
    {error, LastError};
open_db(Opts, State0, RetriesLeft, _) ->
    case eleveldb:open(State0#state.data_root, State0#state.open_opts) of
        {ok, Ref} ->
            {ok, State0#state { ref = Ref }};
        %% Check specifically for lock error, this can be caused if
        %% a crashed instance takes some time to flush leveldb information
        %% out to disk.  The process is gone, but the NIF resource cleanup
        %% may not have completed.
        {error, {db_open, OpenErr}=Reason} ->
            case lists:prefix("IO error: lock ", OpenErr) of
                true ->
                    SleepFor = proplists:get_value(open_retry_delay, Opts, 2000),
                    lager:debug("VerneMQ LevelDB backend retrying ~p in ~p ms after error ~s\n",
                                [State0#state.data_root, SleepFor, OpenErr]),
                    timer:sleep(SleepFor),
                    open_db(Opts, State0, RetriesLeft - 1, Reason);
                false ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.


handle_req({write, {MP, _} = SubscriberId,
            #vmq_msg{msg_ref=MsgRef, mountpoint=MP, dup=Dup, qos=QoS,
                     routing_key=RoutingKey, payload=Payload}},
           #state{ref=Bucket, refs=Refs, write_opts=WriteOpts}) ->
    MsgKey = sext:encode({msg, MsgRef, {MP, ''}}),
    IdxKey = sext:encode({idx, SubscriberId, MsgRef}),
    IdxVal = serialize_p_idx_val_pre(#p_idx_val{ts=os:timestamp(), dup=Dup, qos=QoS}),
    case incr_ref(Refs, MsgRef) of
        1 ->
            %% new message
            Val = serialize_p_msg_val_pre({RoutingKey, Payload}),
            eleveldb:write(Bucket, [{put, MsgKey, Val},
                                    {put, IdxKey, IdxVal}], WriteOpts);
        _ ->
            %% only write the idx
            eleveldb:write(Bucket, [{put, IdxKey, IdxVal}], WriteOpts)
    end;
handle_req({read, {MP, _} = SubscriberId, MsgRef},
           #state{ref=Bucket, read_opts=ReadOpts}) ->
    MsgKey = sext:encode({msg, MsgRef, {MP, ''}}),
    IdxKey = sext:encode({idx, SubscriberId, MsgRef}),
    case eleveldb:get(Bucket, MsgKey, ReadOpts) of
        {ok, Val} ->
            {RoutingKey, Payload} = parse_p_msg_val_pre(Val),
            case eleveldb:get(Bucket, IdxKey, ReadOpts) of
                {ok, IdxVal} ->
                    #p_idx_val{dup=Dup, qos=QoS} = parse_p_idx_val_pre(IdxVal),
                    Msg = #vmq_msg{msg_ref=MsgRef, mountpoint=MP, dup=Dup, qos=QoS,
                                   routing_key=RoutingKey, payload=Payload, persisted=true},
                    {ok, Msg};
                not_found ->
                    {error, idx_val_not_found}
            end;
        not_found ->
            {error, not_found}
    end;
handle_req({delete, {MP, _} = SubscriberId, MsgRef},
           #state{ref=Bucket, refs=Refs, write_opts=WriteOpts}) ->
    MsgKey = sext:encode({msg, MsgRef, {MP, ''}}),
    IdxKey = sext:encode({idx, SubscriberId, MsgRef}),
    case decr_ref(Refs, MsgRef) of
        not_found ->
            lager:warning("delete failed ~p due to not found", [MsgRef]);
        0 ->
            %% last one to be deleted
            eleveldb:write(Bucket, [{delete, IdxKey},
                                    {delete, MsgKey}], WriteOpts);
        _ ->
            %% we have to keep the message, but can delete the idx
            eleveldb:write(Bucket, [{delete, IdxKey}], WriteOpts)
    end;
handle_req({find_for_subscriber_id, TblIdxRef, SubscriberId},
           #state{ref=Bucket, fold_opts=FoldOpts} = State) ->
    {ok, Itr} = eleveldb:iterator(Bucket, FoldOpts),
    FirstIdxKey = sext:encode({idx, SubscriberId, ''}),
    iterate_index_items(eleveldb:iterator_move(Itr, FirstIdxKey),
                        TblIdxRef, SubscriberId, Itr, State).

iterate_index_items({error, _}, _,_, _, _) ->
    %% no need to close the iterator
    ok;
iterate_index_items({ok, IdxKey, IdxVal}, TblIdxRef, SubscriberId, Itr, State) ->
    case sext:decode(IdxKey) of
        {idx, SubscriberId, MsgRef} ->
            #p_idx_val{ts=TS} = parse_p_idx_val_pre(IdxVal),
            Table = select_table(SubscriberId),
            true = ets:insert(Table, {{TblIdxRef, SubscriberId, TS, MsgRef}}),
            iterate_index_items(eleveldb:iterator_move(Itr, prefetch), TblIdxRef, SubscriberId, Itr, State);
        _ ->
            %% all message refs accumulated for this subscriber
            eleveldb:iterator_close(Itr),
            ok
    end.

setup_index(#state{ref=Bucket, fold_opts=FoldOpts, refs=Refs}) ->
    {ok, Itr} = eleveldb:iterator(Bucket, FoldOpts),
    FirstIdxKey = sext:encode({idx, '', ''}),
    setup_index(Refs, eleveldb:iterator_move(Itr, FirstIdxKey), Itr, 0).

setup_index(Refs, {ok, Key, IdxVal}, Itr, N) ->
    case sext:decode(Key) of
        {idx, SubscriberId, MsgRef} ->
            #p_idx_val{ts=TS} = parse_p_idx_val_pre(IdxVal),
            Table = select_table(SubscriberId),
            true = ets:insert(Table, {{init, SubscriberId, TS, MsgRef}}),
            incr_ref(Refs, MsgRef),
            setup_index(Refs, eleveldb:iterator_move(Itr, next), Itr, N + 1);
        _ ->
            eleveldb:iterator_close(Itr),
            N
    end;
setup_index(_Refs, {error, invalid_iterator}, _Itr, N) ->
    N.

incr_ref(Refs, MsgRef) ->
    case ets:insert_new(Refs, {MsgRef, 1}) of
        true -> 1;
        false ->
            ets:update_counter(Refs, MsgRef, 1)
    end.

decr_ref(Refs, MsgRef) ->
    try ets:update_counter(Refs, MsgRef, -1) of
        0 ->
            ets:delete(Refs, MsgRef),
            0;
        V ->
            V
    catch
        _:_ ->
            not_found
    end.

select_table(SubscriberId) ->
    persistent_term:get({?TBL_MSG_INIT, erlang:phash2(SubscriberId, ?NR_OF_BUCKETS) + 1}).

%% pre version idx:
%% {p_idx_val, ts, dup, qos}
%% future version:
%% {p_idx_val, vesion, ts, dup, qos, ...}

%% current version of the index value
-spec parse_p_idx_val_pre(binary()) -> p_idx_val_pre().
parse_p_idx_val_pre(BinTerm) ->
    parse_p_idx_val_pre_(binary_to_term(BinTerm)).

parse_p_idx_val_pre_({TS, Dup, QoS}) ->
    #p_idx_val{ts=TS, dup=Dup, qos=QoS};
%% newer versions of the store -> downgrade
parse_p_idx_val_pre_(T) when element(1,T) =:= p_idx_val,
                             is_integer(element(2, T)),
                             element(2,T) > ?P_IDX_PRE ->
    TS = element(3, T),
    Dup = element(4, T),
    QoS = element(5, T),
    #p_idx_val{ts=TS, dup=Dup, qos=QoS}.

%% current version of the index value
-spec serialize_p_idx_val_pre(p_idx_val_pre()) -> binary().
serialize_p_idx_val_pre(#p_idx_val{ts=TS, dup=Dup, qos=QoS}) ->
    term_to_binary({TS, Dup, QoS});
serialize_p_idx_val_pre(T) when element(1,T) =:= p_idx_val,
                                is_integer(element(2, T)),
                                element(2,T) > ?P_MSG_PRE ->
    term_to_binary(
      {element(3, T),
       element(4, T),
       element(5, T)}).

%% pre msg version:
%% {routing_key, payload}
%% future version:
%% {version, routing_key, payload, ...}

%% parse messages to message type from before versioning.
-spec parse_p_msg_val_pre(binary()) -> p_msg_val_pre().
parse_p_msg_val_pre(BinTerm) ->
    parse_p_msg_val_pre_(binary_to_term(BinTerm)).

parse_p_msg_val_pre_({RoutingKey, Payload}) ->
    {RoutingKey, Payload};
%% newer version of the msg value
parse_p_msg_val_pre_(T) when is_integer(element(1, T)),
                             element(1,T) > ?P_MSG_PRE ->
    {element(2, T),
     element(3, T)}.

%% current version of the msg value
-spec serialize_p_msg_val_pre(p_msg_val_pre()) -> binary().
serialize_p_msg_val_pre({_RoutingKey, _Payload} = T) ->
    term_to_binary(T);
serialize_p_msg_val_pre(T) when is_integer(element(1, T)),
                                element(1,T) > ?P_MSG_PRE ->
    term_to_binary(
      {element(2, T),
       element(3, T)}).
