%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkMEDIA application
-module(nkmedia_janus_engine).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([connect/1, stop/1, find/1]).
-export([stats/2, get_config/1, get_conn/1]).
-export([get_all/0, get_all/1, stop_all/0]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0]).

-define(CONNECT_RETRY, 5000).

-define(LLOG(Type, Txt, Args, State),
	lager:Type("NkMEDIA Janus Engine '~s' "++Txt, [State#state.id|Args])).

-define(CALL_TIME, 30000).
-define(KEEPALIVE, 30000).
-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia:engine_id().

-type config() :: nkmedia:engine_config().

-type status() :: connecting | ready.



%% ===================================================================
%% Public functions
%% ===================================================================

%% @private
-spec connect(config()) ->
	{ok, pid()} | {error, term()}.

connect(#{name:=Name, host:=Host, base:=Base, pass:=Pass}=Config) ->
	case find(Name) of
		not_found ->
			case connect_janus(Host, Base, 10) of
				ok ->
					nkmedia_sup:start_child(?MODULE, Config);
				error ->
					{error, no_connection}
			end;
		{ok, _Status, JanusPid, _ConnPid} ->
			#{vsn:=Vsn, rel:=Rel} = Config,
			case get_config(JanusPid) of
				{ok, #{vsn:=Vsn, rel:=Rel, pass:=Pass}} ->
					{error, {already_started, JanusPid}};
				_ ->
					{error, {incompatible_version}}
			end
	end.


%% @private
stop(Pid) when is_pid(Pid) ->
	gen_server:cast(Pid, stop);

stop(Name) ->
	case find(Name) of
		{ok, _Status, JanusPid, _ConnPid} -> stop(JanusPid);
		not_found -> ok
	end.


%% @private
stats(Id, Stats) ->
	case find(Id) of
		{ok, _Status, JanusPid, _ConnPid} -> gen_server:cast(JanusPid, {stats, Stats});
		not_found -> ok
	end.


%% @private
-spec get_config(id()) ->
	{ok, config()} | {error, term()}.

get_config(Id) ->
	case find(Id) of
		{ok, _Status, JanusPid, _ConnPid} ->
			nklib_util:call(JanusPid, get_config, ?CALL_TIME);
		not_found ->
			{error, no_connection}
	end.


%% @private
-spec get_conn(id()) ->
	{ok, pid()} | {error, term()}.

get_conn(Id) ->
	case find(Id) of
		{ok, ready, _JanusPid, ConnPid} ->
			{ok, ConnPid};
		_ ->
			{error, no_connection}
	end.


%% @doc
-spec get_all() ->
	[{nkservice:id(), id(), pid()}].

get_all() ->
	[{SrvId, Id, Pid} || {{SrvId, Id}, Pid} <- nklib_proc:values(?MODULE)].


%% @doc
-spec get_all(nkservice:id()) ->
	[{id(), pid()}].

get_all(SrvId) ->
	[{Id, Pid} || {S, Id, Pid} <- get_all(), S==SrvId].


%% @private
find(Id) ->
	Id2 = case is_pid(Id) of
		true -> Id;
		false -> nklib_util:to_binary(Id)
	end,
	case nklib_proc:values({?MODULE, Id2}) of
		[{{Status, ConnPid}, JanusPid}] -> {ok, Status, JanusPid, ConnPid};
		[] -> not_found
	end.


%% @private
stop_all() ->
	lists:foreach(fun({_, _, Pid}) -> stop(Pid) end, get_all()).


%% @private 
-spec start_link(config()) ->
    {ok, pid()} | {error, term()}.

start_link(Config) ->
	gen_server:start_link(?MODULE, [Config], []).





% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
	id :: id(),
	config :: config(),
	status :: status(),
	conn :: pid(),
	session :: integer(),
	info = #{} :: map()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([#{srv_id:=SrvId, name:=Id}=Config]) ->
	State = #state{config=Config, id=Id},
	nklib_proc:put(?MODULE, {SrvId, Id}),
	true = nklib_proc:reg({?MODULE, Id}, {connecting, undefined}),
	self() ! connect,
	self() ! keepalive,
	?LLOG(info, "started (~p)", [self()], State),
	{ok, State}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_state, _From, State) ->
	{reply, State, State};

handle_call(get_config, _From, #state{config=Config}=State) ->
    {reply, {ok, Config}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({stats, _Stats}, State) ->
	{noreply, State};

handle_cast(stop, State) ->
	{stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(connect, #state{conn=Pid}=State) when is_pid(Pid) ->
	true = is_process_alive(Pid),
	{noreply, State};

handle_info(connect, #state{id=Id, config=Config}=State) ->
	State2 = update_status(connecting, State#state{conn=undefined}),
	case nkmedia_janus_client:start(Id, Config) of
		{ok, Pid} ->
			case nkmedia_janus_client:info(Pid) of
				{ok, Info} ->
					monitor(process, Pid),
					print_info(Info, State),
					{ok, Session} = nkmedia_janus_client:create(Pid, undefined, Id),
					State3 = State2#state{
						conn = Pid, 
						info = Info,
						session = Session
					},
					{noreply, update_status(ready, State3)};
				{error, Error} ->
					?LLOG(warning, "error response from Janus: ~p", [Error], State2),
					{stop, normal, State2}
			end;
		{error, Error} ->
			?LLOG(warning, "could not connect: ~p", [Error], State2),
			{stop, normal, State2}
	end;

handle_info(keepalive, #state{conn=Conn, session=Session}=State) ->
	case is_pid(Conn) of
		true -> 
			nkmedia_janus_client:keepalive(Conn, Session);
		false ->
			ok
	end,
	erlang:send_after(?KEEPALIVE, self(), keepalive),
	{noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{conn=Pid}=State) ->
	?LLOG(warning, "connection event down", [], State),
	erlang:send_after(?CONNECT_RETRY, self(), connect),
	{noreply, update_status(connecting, State#state{conn=undefined})};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    ?LLOG(info, "stop: ~p", [Reason], State).



% ===================================================================
%% Internal
%% ===================================================================



%% @private
print_info(Map, State) ->
	#{
		<<"local-ip">> := LocalIp,
		<<"version">> := Vsn,
		<<"plugins">> := Plugins
	} = Map,
	PublicIp = maps:get(<<"public-ip">>, Map, <<>>),
	PluginNames = [N || <<"janus.plugin.", N/binary>> <- maps:keys(Plugins)],
	?LLOG(info, "Janus vsn ~p (local ~s, remote ~s). Plugins: ~s",
		  [Vsn, LocalIp, PublicIp, nklib_util:bjoin(PluginNames)], State).



%% @private
update_status(Status, #state{status=Status}=State) ->
	State;

update_status(NewStatus, #state{id=Id, status=OldStatus, conn=Pid}=State) ->
	nklib_proc:put({?MODULE, Id}, {NewStatus, Pid}),
	nklib_proc:put({?MODULE, self()}, {NewStatus, Pid}),
	?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State),
	State#state{status=NewStatus}.
	% send_update(#{}, State#state{status=NewStatus}).


%% @private
connect_janus(_Host, _Base, 0) ->
	error;
connect_janus(Host, Base, Tries) ->
	Host2 = nklib_util:to_list(Host),
	case gen_tcp:connect(Host2, Base, [{active, false}, binary], 5000) of
		{ok, Socket} ->
			gen_tcp:close(Socket),
			ok;
		{error, _} ->
			lager:info("Waiting for Janus at ~s to start (~p) ...", [Host, Tries]),
			timer:sleep(1000),
			connect_janus(Host2, Base, Tries-1)
	end.





