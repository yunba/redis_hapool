%%%-------------------------------------------------------------------
%%% @author thi
%%% @copyright (C) 2015, yunba.io
%%% @doc
%%%
%%% @end
%%% Created : 14. 四月 2015 下午2:46
%%%-------------------------------------------------------------------
-module(redis_hapool_server).
-author("thi").

-include_lib("elog/include/elog.hrl").
-include_lib("stdlib/include/qlc.hrl").
-include("redis_hapool.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1
    , poolname/1
    , redis_connection_changed/4, q/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-define(CHECK_MNESIA_TIME_INTERVAL, 2000).
-define(CHECK_MNESIA_TIMER, check_mnesia_timer).

-define(REDIS_RECOVERY_TIME_INTERVAL, 2000).
-define(REDIS_RECOVERY_TIMER, redis_recovery_timer).

-record(state, {
    redis_infos         ::redis_info_list(),
    redis_connections   ::redis_connection_list(),
    invalid_connections ::redis_connection_list()
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(redis_info_list()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(RedisPool) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [RedisPool], []).

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
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([RedisInfos]) ->
    lager:log(info, self(), "redis_pool init pools with info ~p", [RedisInfos]),

    {RedisConnections, InvalidConnections} = update_redis_connection_by_info(RedisInfos, []),

    resource_discovery:add_local_resource_tuple({?REDISES_INFO_TABLE, node()}),
    resource_discovery:add_target_resource_type(?REDISES_INFO_TABLE),
    ok = resource_discovery:sync_resources(2500),

    ClientNodes = resource_discovery:get_resources(?REDISES_INFO_TABLE),

    create_redis_infos_table(lists:delete(node(), ClientNodes)),
    create_ets_redis_connections(),

    update_mnesia_redis_info(RedisInfos),
    update_ets_redis_connections(RedisConnections),

    %schedule_check_mnesia_redis_info(),
    schedule_redis_recovery(),

    lager:log(info, self(), "redis_pool started connection pools ~p", [RedisConnections]),
    {ok, #state{redis_infos = RedisInfos, redis_connections = RedisConnections, invalid_connections = InvalidConnections}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call({q, Command}, _From, State = #state{
    redis_connections = RedisConnections,
    invalid_connections = InvalidConnections}) ->
    %% select a connection from redis_connections
    %% if there is no connection available, return error
    case try_to_exec_command(RedisConnections, InvalidConnections, Command, 2) of
        {error, Error, RedisConnections2, InvalidConnections2} ->
            {reply, {error, Error}, State#state{redis_connections = RedisConnections2,
                invalid_connections = InvalidConnections2}};
        {ok, Value} ->
            {reply, {ok, Value}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

try_to_exec_command(RedisConnections, InvalidConnections, Command, TryCount) ->
    case RedisConnections of
        [Connection | RestConnection] ->
            [Connection | RestConnection] = RedisConnections,
            Pool = poolname(Connection),
            %% try to exec the command
            Ret = eredis_pool:q(Pool, Command),
            case Ret of
                {error, Error}  ->
                    InvalidConnections2 = lists:append(InvalidConnections, [Connection]),
                    if
                    %% if failed, try the next connection and move the connection to invalid_connections
                        TryCount == 0 ->
                            {error, Error, RestConnection, InvalidConnections2};
                        true ->
                            try_to_exec_command(RestConnection, InvalidConnections2, Command, TryCount - 1)
                    end;
                {ok, Value} ->
                    {ok, Value}
            end;
        _Empty ->
            {error, no_valid_connection, RedisConnections, InvalidConnections}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).

handle_cast(
    {redis_connection_changed, FromRedisConnections, ToRedisConnections,InvalidRedisConnectionsInfo},
    State = #state{redis_infos = _OldRedisInfos, redis_connections = OldRedisConnections,
        invalid_connections = OldInvalidConnections}) ->
    case FromRedisConnections == OldRedisConnections of
        true ->
            ToInvalidConnections = case InvalidRedisConnectionsInfo of
                                       {add, N} -> OldInvalidConnections ++ N;
                                       {replace, N} -> N
                                   end,
            %% changed really, do updte mnesia redis infos
            ToRedisInfos = [C#redis_connection.info || C <- ToRedisConnections],
            ?ERROR("changed connection from connections [~p], to connections [~p], infos [~p]", [FromRedisConnections, ToRedisConnections, ToRedisInfos]),
            update_mnesia_redis_info(ToRedisInfos),
            update_ets_redis_connections(ToRedisConnections),
            {noreply, State#state{redis_infos = ToRedisInfos, redis_connections = ToRedisConnections, invalid_connections = ToInvalidConnections}};
        _ ->
            %% changed from invalid connection info, just drop it
            ?ERROR("droped changed connection from uncompatible connections [~p], old connections [~p], just drop it", [FromRedisConnections, OldRedisConnections]),
            {noreply, State}
    end;

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
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(?CHECK_MNESIA_TIMER, State = #state{redis_infos = OldRedisInfos, redis_connections = OldRedisConnections, invalid_connections = OldInvalidConnections}) ->
    NewRedisInfos = case mnesia:dirty_read(?REDISES_INFO_TABLE, ?REDISES_INFO_TABLE_ID) of
                        [{?REDISES_INFO_TABLE, ?REDISES_INFO_TABLE_ID, Infos}] -> Infos;
    %% use old redis infos when mnesia failed
                        MnesiaResult ->
                            lager:log(error, self(), "mnesia: dirty_read failed [~p]", [MnesiaResult]),
                            OldRedisInfos
                    end,
    ?DEBUG("checking mnesia redis infos", []),
    case NewRedisInfos == OldRedisInfos of
        true ->
            %% redis info not changed
            {noreply, State};
        false ->
            OldAllRedisConnection = OldRedisConnections ++ OldInvalidConnections,
            %% redis info changed
            {NewRedisConnections, NewInvalidConnections} = update_redis_connection_by_info(NewRedisInfos, OldAllRedisConnection),
            ?ERROR("infos [~p] -> [~p], connections [~p] -> [~p]", [OldRedisInfos, NewRedisInfos, OldRedisConnections, NewRedisConnections]),
            update_ets_redis_connections(NewRedisConnections),
            {noreply, State#state{redis_infos = NewRedisInfos, redis_connections = NewRedisConnections, invalid_connections = NewInvalidConnections}}
    end;

handle_info(?REDIS_RECOVERY_TIMER, State = #state{redis_connections = OldRedisConnections, invalid_connections = OldInvalidConnections}) ->
    CheckInvalidConnectionResults = lists:map(
        fun(C) ->
            case is_redis_valid(C) of
                true -> {true, C};
                false -> {false, C}
            end
        end, OldInvalidConnections
    ),
    NewInvalidConnections = lists:filtermap(
        fun({Valid, C}) ->
            case Valid of
                true -> false;
                false -> {true, C}
            end
        end, CheckInvalidConnectionResults
    ),
    RecoveredRedisConnections = lists:filtermap(
        fun({Valid, C}) ->
            case Valid of
                true -> {true, C};
                false -> false
            end
        end, CheckInvalidConnectionResults
    ),
    ToRedisConnections = OldRedisConnections ++ RecoveredRedisConnections,

    case erlang:length(RecoveredRedisConnections) of
        0 ->
            % no redis connection recovered
            ?INFO("tried to recover redis connections [~p], and none recovery", [OldInvalidConnections]);
        _ ->
            ?INFO("recovered redis connections [~p] from [~p]", [RecoveredRedisConnections, OldInvalidConnections]),
            redis_connection_changed(?MODULE, OldRedisConnections, ToRedisConnections, {replace, NewInvalidConnections})
    end,
    {noreply, State};

handle_info(_Info, State) ->
    ?ERROR("handle unknown info [~p]", [_Info]),
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
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% APIs
%%

-spec q(Command::iolist()) ->
    {ok, binary() | [binary()]} | {error, Reason::binary()}.
q(Command) ->
    gen_server:call(?MODULE, {q, Command}).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% remove failed redis && renew redis_pool list

-spec (poolname(#redis_connection{}) -> atom()).
poolname(_RedisConnection = #redis_connection{info = Info}) ->
    {PoolName, _Size, _Overflow, _Host, _Port} = Info,
    PoolName.

-spec (find_connection_by_info(redis_info(), redis_connection_list()) -> {true, #redis_connection{}} | false).
find_connection_by_info(RedisInfo, RedisConnections) ->
    FilterResult = lists:filter(
        fun (C) ->
            C#redis_connection.info == RedisInfo
        end, RedisConnections),
    case length(FilterResult) of
        0 -> false;
        _ -> {true, lists:nth(1, FilterResult)}
    end.

-spec (find_info_by_connection(#redis_connection{}, redis_info_list()) -> {true, #redis_connection{}} | false).
find_info_by_connection(RedisConnection, RedisInfos) ->
    FilterResult = lists:filter(
        fun (I) ->
            RedisConnection#redis_connection.info == I
        end, RedisInfos),
    case length(FilterResult) of
        0 -> false;
        _ -> {true, lists:nth(1, FilterResult)}
    end.

-spec (get_connection_by_info(redis_info(), redis_connection_list()) -> {true, #redis_connection{}} | false).
get_connection_by_info(RedisInfo, RedisConnections) ->
    case find_connection_by_info(RedisInfo, RedisConnections) of
        {true, C} -> C;
        false -> new_connection_by_info(RedisInfo)
    end.

%-spec (remove_connection(#redis_connection{}) -> ok).
%remove_connection(RedisConnection = #redis_connection{info = {Poolname, _Size, _Overflow, _Host, _port}}) ->
%    eredis_pool:delete_pool(Poolname),
%    RedisConnection.

-spec (update_redis_connection_by_info(list(), list(#redis_connection{})) -> {redis_connection_list(), redis_connection_list()}).
update_redis_connection_by_info(RedisInfos, RedisConnections) ->
    NewConnections = [get_connection_by_info(I, RedisConnections) || I <- RedisInfos],

    %% handle useless connections
    %_NewInvalidConnections = [
    %    remove_connection(C)
    %    || C <- RedisConnections, false = find_info_by_connection(C, RedisInfos)
    %],
    NewInvalidConnections = lists:filter(
    fun (C) ->
        case find_info_by_connection(C, RedisInfos) of
            {true, _} -> false;
            false -> true
        end
    end, RedisConnections),
    {NewConnections, NewInvalidConnections}.

-spec (new_connection_by_info(redis_info()) -> #redis_connection{}).
new_connection_by_info(RedisInfo) ->
    {PoolName, Size, MaxOverflow, Host, Port} = RedisInfo,
    lager:log(debug, self(), "create pool with info [~p] ", [RedisInfo]),
    Result = eredis_pool:create_pool(PoolName, {Size, MaxOverflow}, Host, Port),
    lager:log(info, self(), "create pool result [~p]", [Result]),
    #redis_connection{info = RedisInfo, status = read_write}.

%% mnesia operations
-spec (create_redis_infos_table(list()) -> ok).
create_redis_infos_table([]) ->
    case mnesia_table_exists(?REDISES_INFO_TABLE) of
        false ->
            mnesia:stop(),
            mnesia:delete_schema([node()]),
            mnesia:create_schema([node()]),
            mnesia:start(),

            case mnesia:create_table(?REDISES_INFO_TABLE,
                %[{index, [#?REDISES_INFO_TABLE.info_id]}, {attributes, record_info(fields, ?REDISES_INFO_TABLE)}]) of
                [{attributes, record_info(fields, ?REDISES_INFO_TABLE)}]) of
                {atomic, ok} ->
                    lager:log(info, self(), "mnesia: create table ~p", [?REDISES_INFO_TABLE]),
                    ok;
                {aborted, Reason} ->
                    lager:log(error, self(), "mnesia: create table ~p fail: ~p", [?REDISES_INFO_TABLE, Reason]),
                    error
            end;
        _ ->
            ok
    end;
create_redis_infos_table(ClientNodes) ->
    get_redis_pool_table_nodes(ClientNodes).

mnesia_table_exists(TableName) ->
    try
        Tables = mnesia:system_info(tables),
        lists:member(TableName,Tables)
    catch
        _->
            false
    end.

get_redis_pool_table_nodes(Node) ->
    case mnesia:change_config(extra_db_nodes, [Node]) of
        {ok, [Node]} ->
            mnesia:add_table_copy(?REDISES_INFO_TABLE, node(), ram_copies),
            mnesia:wait_for_tables(mnesia:system_info(tables), infinity),
            ok;
        Error -> Error
    end.

-spec (update_mnesia_redis_info(redis_info_list()) -> ok | {error, term()}).
update_mnesia_redis_info(OkInfos) ->
    F = fun() ->
        mnesia:dirty_delete({?REDISES_INFO_TABLE, ?REDISES_INFO_TABLE_ID}),
        mnesia:dirty_write(#?REDISES_INFO_TABLE{info_id = ?REDISES_INFO_TABLE_ID, infos = OkInfos}),
        {ok}
    end,
    case mnesia:transaction(F) of
        {atomic, ResultOfFun} ->
            ResultOfFun;
        {aborted, Reason} ->
            lager:log(error, self(), "update mnesia redis info failed [~p]", [Reason]),
            {error, Reason}
    end.


-spec (create_ets_redis_connections() -> ok | {error, term()}).
create_ets_redis_connections() ->
    ets:new(?REDISES_CONNECTION_TABLE, [set, protected, named_table, {keypos,1}, {write_concurrency,false}, {read_concurrency,true}]).

-spec (update_ets_redis_connections(redis_connection_list()) -> ok | {error, term()}).
update_ets_redis_connections(OkConnections) ->
    try
        lager:log(debug, self(), "write connections[~p] to ets", [OkConnections]),
        ets:insert(?REDISES_CONNECTION_TABLE, [{?REDISES_CONNECTION_LIST, OkConnections}]),
        lager:log(debug, self(), "all ets connections[~p] ", [ets:tab2list(?REDISES_CONNECTION_TABLE)])
    catch E:T ->
        lager:log(error, self(), "update ets redis connection failed[~p:~p]", [E, T])
    end.

-spec (schedule_check_mnesia_redis_info() -> ok).
schedule_check_mnesia_redis_info() ->
    timer:send_interval(?CHECK_MNESIA_TIME_INTERVAL, ?SERVER, ?CHECK_MNESIA_TIMER).

-spec (schedule_redis_recovery() -> ok).
schedule_redis_recovery() ->
    timer:send_interval(?REDIS_RECOVERY_TIME_INTERVAL, ?SERVER, ?REDIS_RECOVERY_TIMER).

-define(CHECK_REDIS_KEY_COUNT, 20).
-spec (is_redis_valid(#redis_connection{}) -> ok).
is_redis_valid(Connection) ->
    PoolName = redis_hapool_server:poolname(Connection),
    TestKeys = lists:seq(1, ?CHECK_REDIS_KEY_COUNT),
    Result = eredis_pool:q(PoolName, ["MGET"] ++ TestKeys),
    case Result of
        {ok, _ListResult} ->
            true;
        _ -> false
    end.

-spec (redis_connection_changed(atom(), redis_connection_list(), redis_connection_list(), {add|replace, redis_connection_list()}) -> ok | {error, term()}).
redis_connection_changed(RedisPollMng, OldRedisConnectionList, RedisConnectionList, InvalidConnectionInfo) ->
    gen_server:cast(RedisPollMng, {redis_connection_changed, OldRedisConnectionList, RedisConnectionList, InvalidConnectionInfo}).