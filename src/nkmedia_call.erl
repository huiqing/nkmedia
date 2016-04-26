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


-module(nkmedia_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/1, get_status/1]).
-export([hangup/1, hangup/2, hangup_all/0]).
-export([session_event/3, find/1, get_all/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Call ~s (~p) "++Txt, 
               [State#state.id, State#state.status | Args])).

-include("nkmedia.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


-type config() :: 
    #{
        id => id(),       
        srv_id => nkservice:id(),              
        offer => nkmedia:offer(),
        session_id => nkmedia_session:id(),
        session_pid => pid(),
        call_dest => term(),
        calling_timeout => integer(),          % Secs
        ring_timeout => integer(),          
        ready_timeout => integer(),
        call_timeout => integer(),
        mediaserver => nkmedia_session:mediaserver(),
        term() => term()                         % User defined
    }.


-type status() ::
    calling | ringing | bridged | p2p | hangup.


-type status_info() :: nkmedia_session:status_info().


-type call() ::
    config() |
    #{
        status => status(),
        status_info => map(),
        answer => nkmedia:answer()
    }.


-type event() ::
    {status, status(), status_info()} | {info, term()}.


-type call_out_spec() ::
    [call_out()] | nkmedia_session:call_dest().


-type call_out() ::
    #{
        dest => nkmedia_session:call_dest(),
        wait => integer(),              %% secs
        ring => integer()
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call
-spec start(config()) ->
    {ok, id(), pid()}.

start(Config) ->
    {CallId, Config2} = nkmedia_util:add_uuid(Config),
    {ok, Pid} = gen_server:start(?MODULE, [Config2], []),
    {ok, CallId, Pid}.


%% @private
hangup_all() ->
    lists:foreach(fun({CallId, _Pid}) -> hangup(CallId) end, get_all()).


%% @doc
-spec hangup(id()) ->
    ok | {error, term()}.

hangup(CallId) ->
    hangup(CallId, 16).


%% @doc
-spec hangup(id(), nkmedia:hangup_reason()) ->
    ok | {error, term()}.

hangup(CallId, Reason) ->
    do_cast(CallId, {hangup, Reason}).


%% @doc
-spec get_status(id()) ->
    {ok, status(), status_info(), integer()}.

get_status(SessId) ->
    do_call(SessId, get_status).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% ===================================================================
%% Private
%% ===================================================================

session_event(CallId, SessId, Event) ->
    do_cast(CallId, {session_event, SessId, Event}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(session_out, {
    dest :: nkmedia_session:call_out(),
    ring :: integer(),
    pos :: integer(),
    launched :: boolean(),
    pid :: pid()
}).

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    call :: call(),
    status :: status(),
    % answered :: boolean(),
    % notify_refs :: nkmedia_util:notify_refs(),
    session_in :: {nkmedia_session:id(), pid(), reference()},
    session_out :: {nkmedia_session:id(), pid(), reference()},
    outs = #{} :: #{nkmedia_session:id() => #session_out{}},
    out_pos = 0 :: integer(),
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init([#{id:=Id, srv_id:=SrvId, session_id:=SessId, session_pid:=SessPid}=Call]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    State = #state{
        id = Id, 
        srv_id = SrvId, 
        status = init,
        call = Call,
        session_in = {SessId, SessPid, monitor(process, SessPid)}
    },
    lager:info("NkMEDIA Call ~s starting (~p)", [Id, self()]),
    {ok, State2} = handle(nkmedia_call_init, [Id], State),
    gen_server:cast(self(), start),
    {ok, status(calling, State2)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_status, _From, State) ->
    #state{status=Status, timer=Timer, call=Call} = State,
    #{status_info:=Info} = Call,
    {reply, {ok, Status, Info, erlang:read_timer(Timer) div 1000}, State};

handle_call({launch_outs, CallSpec}, _From, State) ->
    {reply, ok, launch_outs(CallSpec, State)};

handle_call(Msg, From, State) -> 
    handle(nkmedia_call_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(start, State) ->
    {noreply, get_outbound(State)};

handle_cast({session_event, SessId, Event}, State) ->
    #state{session_out=Out, outs=Outs} = State,
    State2 = case Out of
        {SessId, _, _} ->
            ?LLOG(info, "event from outbound session: ~p", [Event], State),
            process_out_event(Event, State);
        _ ->
            case maps:find(SessId, Outs) of
                {ok, CallOut}  ->
                    process_call_out_event(Event, SessId, CallOut, State);
                false ->
                    ?LLOG(warning, "event from unknown session", [Event], State),
                    State
            end
    end,
    {noreply, State2};

handle_cast({hangup, Reason}, State) ->
    {stop, normal, do_hangup(Reason, State)};

handle_cast(stop, State) ->
    ?LLOG(notice, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    handle(nkmedia_call_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({launch_out, SessId}, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    case find_out(SessId, State) of
        {ok, #session_out{launched=false, ring=Ring}=Out} ->
            erlang:send_after(1000*Ring, self(), {ring_timeout, SessId}),
            {noreply, launch_out(SessId, Out, State)};
        {ok, Out} ->
            {noreply, launch_out(SessId, Out, State)};
        not_found ->
            % The call can have been removed because of timeout
            {noreply, State}
    end;

handle_info({launch_out, SessId}, State) ->
    {noreply, remove_out(SessId, State)};

handle_info({ring_timeout, SessId}, State) ->
    case find_out(SessId, State) of
        {ok, #session_out{dest=Dest, pos=Pos, launched=Launched}} ->
            ?LLOG(notice, "call ring timeout for ~p (~p, ~s)", 
                  [Dest, Pos, SessId], State),
            case Launched of
                true -> 
                    nkmedia_session:hangup(SessId, <<"Ring Timeout">>);
                false ->
                    ok
            end,
            {noreply, remove_out(SessId, State)};
        not_found ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_in={_, _, Ref}}=State) ->
    ?LLOG(warning, "inbound session stopped: ~p", [Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{session_out={_, _, Ref}}=State) ->
    ?LLOG(warning, "outbound session out stopped: ~p", [Reason], State),
    %% Should enter into 'recovery' mode
    {stop, normal, State};

% handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{notify_refs=Refs}=State) ->
%     case lists:keytake(Ref, 2, Refs) of
%         {value, {Notify, Ref}, Refs2} ->
%             ?LLOG(warning, "notify ~p stopped!: ~p", [Notify, Reason], State),
%             %% Should call a callback and maybe enter into 'recovery' mode
%             {stop, normal, State#state{notify_refs=Refs2}};
%         false ->
%             ?LLOG(warning, "unexpected DOWN: ~p", [Reason], State),
%             {noreply, State}
%     end;

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    hangup(self(), 607),
    {noreply, State};

handle_info(Msg, #state{}=State) -> 
    lager:warning("CALL INFO: ~p", [Msg]),
    handle(nkmedia_call_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(nkmedia_call_code_change, 
                                 OldVsn, State, Extra, 
                                 #state.srv_id, #state.call).

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    catch handle(nkmedia_call_terminate, [Reason], State),
    State2 = do_hangup("Session Stop", State), % Probably it is already
    ?LLOG(info, "stopped (~p)", [Reason], State2).


% ===================================================================
%% Internal
%% ===================================================================


-spec get_outbound(#state{}) ->
    #state{}.

get_outbound(#state{call=Call}=State) ->
    #{offer:=Offer, mediaserver:=MS} = Call,
    #{callee_id:=CalleeId} = Offer,
    case handle(nkmedia_call_resolve, [CalleeId], State) of
        {ok, OutSpec, State3} ->
            #state{outs=Outs} = State4 = launch_outs(OutSpec, State3),
            ?LLOG(info, "resolved outs: ~p", [Outs], State4),
            case map_size(Outs) of
                0 ->
                    hangup(self(), <<"No Destination">>);
                Size when MS==none, Size>1 ->
                    hangup(self(), <<"Multiple Calls Not Allowed">>);
                _ ->
                    ok
            end,
            State4;
        {hangup, Reason, State3} ->
            ?LLOG(info, "nkmedia_call_resolve: hangup (~p)", [Reason], State),
            hangup(self(), Reason),
            State3
    end.


%% @private Generate data and launch messages
-spec launch_outs(call_out_spec(), State) ->
    State.

launch_outs([], State) ->
    State;

launch_outs([CallOut|Rest], #state{outs=Outs, call=Call, out_pos=Pos}=State) ->
    #{dest:=Dest} = CallOut,
    Wait = case maps:find(wait, CallOut) of
        {ok, Wait0} -> Wait0;
        error -> 0
    end,
    Ring = case maps:find(ring, CallOut) of
        {ok, Ring0} -> Ring0;
        error -> maps:get(ring_timeout, Call, ?DEF_RING_TIMEOUT)
    end,
    SessId = nklib_util:uuid_4122(),
    Out = #session_out{dest=Dest, ring=Ring, pos=Pos, launched=false},
    Outs2 = maps:put(SessId, Out, Outs),
    case Wait of
        0 -> self() ! {launch_out, SessId};
        _ -> erlang:send_after(1000*Wait, self(), {launch_out, SessId})
    end,
    launch_outs(Rest, State#state{outs=Outs2, out_pos=Pos+1});

launch_outs(Dest, State) ->
    launch_outs([#{dest=>Dest}], State).


%% @private
launch_out(SessId, #session_out{dest=Dest, pos=Pos}=Out, State) ->
    #state{
        id = Id, 
        call = Call, 
        srv_id = SrvId, 
        outs = Outs,
        session_in = {SessIn, _, _}
    } = State,
    case handle(nkmedia_call_out, [Id, SessId, Dest], State) of
        {call, Dest2, State2} ->
            ?LLOG(info, "launching out ~p (~p)", [Dest, Pos], State),
            Opts = Call#{
                id => SessId, 
                monitor => self(),
                nkmedia_call_id => Id,
                nkmedia_session_id => SessIn,
                call_dest => Dest2
            },
            {ok, SessId, Pid} = nkmedia_session:start_outbound(SrvId, Opts),
            Out2 = Out#session_out{launched=true, pid=Pid},
            Outs2 = maps:put(SessId, Out2, Outs),
            State2#state{outs=Outs2};
        {retry, Secs, State2} ->
            ?LLOG(info, "retrying out ~p (~p, ~p secs)", [Dest, Pos, Secs], State),
            erlang:send_after(1000*Secs, self(), {launch_out, SessId}),
            State2;
        {remove, State2} ->
            ?LLOG(info, "removing out ~p (~p)", [Dest, Pos], State),
            remove_out(SessId, State2)
    end.


%% @private
find_out(SessId, #state{outs=Outs}) ->
    case maps:find(SessId, Outs) of
        {ok, Out} -> {ok, Out};
        error -> not_found
    end.


%% @private
remove_out(SessId, #state{outs=Outs, status=Status}=State) ->
    case maps:find(SessId, Outs) of
        {ok, #session_out{pos=Pos}} ->
            Outs2 = maps:remove(SessId, Outs),
            case map_size(Outs2) of
                0 when Status==calling; Status==ringing ->
                    ?LLOG(notice, "all outs removed", [], State),
                    hangup(self(), <<"No Answer">>),
                    State#state{outs=Outs2};
                _ -> 
                    ?LLOG(info, "removed out ~s (~p)", [SessId, Pos], State),
                    %% We shouuld hibernate
                    State#state{outs=Outs2}
            end;
        error ->
            State
    end.


%% @private
process_out_event({status, hangup, _Data}, State) ->
    hangup(self(), <<"Callee Hangup">>),
    State;

process_out_event(_Event, State) ->
    lager:warning("CALL EVENT: ~p", [_Event]),
    State.


%% @private
process_call_out_event({status, calling, _Data}, _SessId, _Out, State) ->
    State;

process_call_out_event({status, ringing, _Data}, _SessId, _Out, State) ->
    status(ringing, State);

process_call_out_event({status, p2p, _Data}, SessId, #session_out{pid=Pid}, State) ->
    out_answered(SessId, Pid, State);

process_call_out_event({status, hangup, _Data}, SessId, _OutCall, State) ->
    remove_out(SessId, State);
    
process_call_out_event(_Event, _SessId, _OutCall, State) ->
    lager:warning("CALL OUT EVENT: ~p", [_Event]),
    State.


%% @private
out_answered(SessId, SessPid, #state{status=Status}=State)
        when Status==calling; Status==ringing ->
    SessOut = {SessId, SessPid, monitor(process, SessPid)},
    State2 = State#state{session_out=SessOut},
    State3 = status(p2p, #{peer=>SessId}, State2),
    State4 = remove_out(SessId, State3),
    hangup_all_outs(State4);

out_answered(SessId, SessPid, State) ->
    nkmedia_session:hangup(SessPid, <<"Already Answered">>),
    remove_out(SessId, State).


%% @private Use this to generate hangup code, otherwise terminate will call it
do_hangup(_Reason, #state{status=hangup}=State) ->
    State;

do_hangup(Reason, State) ->
    #state{session_in=SessIn, session_out=SessOut} = State,
    State2 = hangup_all_outs(State),
    case SessIn of 
        {In, _, _} -> lager:warning("HANGUP3"), nkmedia_session:hangup(In, Reason);
        undefined -> ok
    end,
    case SessOut of 
        {Out, _, _} ->  lager:warning("HANGUP3"), nkmedia_session:hangup(Out, Reason);
        undefined -> ok
    end,
    Info = #{q850=>nkmedia_util:get_q850(Reason)},
    status(hangup, Info, State2).


%% @private
hangup_all_outs(#state{outs=Outs}=State) ->
    lists:foreach(
        fun
            ({SessId, #session_out{launched=true}}) ->
                nkmedia_session:hangup(SessId, <<"User Canceled">>);
            ({_, _}) ->
                ok
        end,
        maps:to_list(Outs)),
    State#state{outs=#{}}.


%% @private
status(Status, State) ->
    status(Status, #{}, State).


%% @private
status(Status, _Info, #state{status=Status}=State) ->
    restart_timer(State);

status(NewStatus, Info, #state{status=OldStatus, call=Call}=State) ->
    State2 = restart_timer(State#state{status=NewStatus}),
    State3 = State2#state{call=Call#{status=>NewStatus, status_info=>Info}},
    ?LLOG(info, "status ~p -> ~p", [OldStatus, NewStatus], State3),
    notify({status, NewStatus, Info}, State3).


%% @private
notify(Event, #state{id=Id}=State) ->
    {ok, State2} = handle(nkmedia_call_notify, [Id, Event], State),
    State2.


%% @private
restart_timer(#state{status=hangup, timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    State;

restart_timer(#state{status=Status, timer=Timer, call=Call}=State) ->
    nklib_util:cancel_timer(Timer),
    Time = case Status of
        calling -> maps:get(ring_timeout, Call, ?DEF_RING_TIMEOUT);
        ringing -> maps:get(ring_timeout, Call, ?DEF_RING_TIMEOUT);
        ready -> maps:get(ready_timeout, Call, ?DEF_READY_TIMEOUT);
        _ -> maps:get(call_timeout, Call, ?DEF_CALL_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{timer=NewTimer}.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.call).


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(CallId) ->
    case nklib_proc:values({?MODULE, CallId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(CallId, Msg) ->
    do_call(CallId, Msg, 5000).


%% @private
do_call(CallId, Msg, Timeout) ->
    case find(CallId) of
        {ok, Pid} -> nklib_util:call(Pid, Msg, Timeout);
        not_found -> {error, call_not_found}
    end.


%% @private
do_cast(CallId, Msg) ->
    case find(CallId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, call_not_found}
    end.


