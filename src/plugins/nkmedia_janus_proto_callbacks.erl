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

-module(nkmedia_janus_proto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_janus_init/2, nkmedia_janus_login/4, nkmedia_janus_call/3,
         nkmedia_janus_invite/3, nkmedia_janus_answer/3, nkmedia_janus_bye/2,
         nkmedia_janus_start/3, nkmedia_janus_terminate/2,
         nkmedia_janus_handle_call/3, nkmedia_janus_handle_cast/2,
         nkmedia_janus_handle_info/2]).
-export([nkmedia_session_invite/4, nkmedia_session_event/3]).
-export([nkmedia_call_resolve/2]).


-define(JANUS_WS_TIMEOUT, 60*60*1000).


%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(janus, nkmedia_janus_proto),
    #{
        janus_listen => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % janus_listen will be already parsed
    Listen = maps:get(janus_listen, Config, []),
    Opts = #{
        class => {nkmedia_janus_proto, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?JANUS_WS_TIMEOUT,
        ws_proto => <<"janus-protocol">>
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA JANUS Proto (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA JANUS Proto (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================



-type janus() :: nkmedia_janus:janus().
-type call_id() :: nkmedia_janus:call_id().
-type continue() :: continue | {continue, list()}.


%% @doc Called when a new janus connection arrives
-spec nkmedia_janus_init(nkpacket:nkport(), janus()) ->
    {ok, janus()}.

nkmedia_janus_init(_NkPort, Janus) ->
    {ok, Janus}.


%% @doc Called when a login request is received
-spec nkmedia_janus_login(JanusSessId::binary(), Login::binary(), Pass::binary(),
                          janus()) ->
    {boolean(), janus()} | {true, Login::binary(), janus()} | continue().

nkmedia_janus_login(_JanusId, _Login, _Pass, Janus) ->
    {false, Janus}.


%% @doc Called when the client sends an INVITE
%% If {ok, janus(), pid()} is returned, we must call nkmedia_janus:answer/3 ourselves
%% A call will be added. If pid() is included, it will be associated to it
-spec nkmedia_janus_invite(call_id(), nkmedia_janus:offer(), janus()) ->
    {ok, pid()|undefined, janus()} | 
    {answer, nkmedia_janus:answer(), pid()|undefined, janus()} | 
    {hangup, nkmedia:hangup_reason(), janus()} | continue().

nkmedia_janus_invite(SessId, Offer, #{srv_id:=SrvId}=Janus) ->
    #{sdp_type:=webrtc} = Offer,
    Offer2 = Offer#{pid=>self(), nkmedia_janus_proto=>in},
    case nkmedia_session:start(SrvId, #{id=>SessId}) of
        {ok, SessId, SessPid} ->
            case SrvId:nkmedia_janus_call(SessId, Offer2, Janus) of
                {ok, Janus2} ->
                    {ok, SessPid, Janus2};
                {rejected, Reason, Janus2} ->
                    nkmedia_session:hangup(SessId, Reason),
                    {hangup, Reason, Janus2}
            end;
        {error, Error} ->
            lager:warning("Janus start_inbound error: ~p", [Error]),
            {hangup, <<"MediaServer Error">>, Janus}
    end.


%% @doc Sends after an INVITE, if the previous function has not been modified
-spec nkmedia_janus_call(call_id(), binary(), janus()) ->
    {ok, janus()} | {hangup, nkmedia:hangup_reason(), janus()} | continue().

nkmedia_janus_call(CallId, Dest, Janus) ->
    ok = nkmedia_session:answer_async(CallId, {invite, Dest}, #{}),
    {ok, Janus}.


%% @doc Called when the client sends an ANSWER
-spec nkmedia_janus_answer(call_id(), nkmedia_janus:answer(), janus()) ->
    {ok, janus()} |{hangup, nkmedia:hangup_reason(), janus()} | continue().

nkmedia_janus_answer(CallId, Answer, Janus) ->
    case nkmedia_session:invite_reply(CallId, {answered, Answer}) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            lager:error("No Session: ~p: ~p", [CallId, Error]),
            {hangup, <<"No Session">>, Janus}
    end.


%% @doc Sends when the client sends a BYE
-spec nkmedia_janus_bye(call_id(), janus()) ->
    {ok, janus()} | continue().

nkmedia_janus_bye(CallId, Janus) ->
    nkmedia_session:hangup(CallId, <<"User Hangup">>),
    {ok, Janus}.


%% @doc Called when the client sends an START for a PLAY
-spec nkmedia_janus_start(call_id(), nkmedia_janus:offer(), janus()) ->
    ok | {hangup, nkmedia:hangup_reason(), janus()} | continue().

nkmedia_janus_start(SessId, Answer, Janus) ->
    case nkmedia_session:answer_async(SessId, Answer, #{}) of
        ok ->
            {ok, Janus};
        {error, Error} ->
            lager:warning("Janus janus_start error: ~p", [Error]),
            {hangup, <<"MediaServer Error">>, Janus}
    end.


%% @doc Called when the connection is stopped
-spec nkmedia_janus_terminate(Reason::term(), janus()) ->
    {ok, janus()}.

nkmedia_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_call(Msg::term(), {pid(), term()}, janus()) ->
    {ok, janus()} | continue().

nkmedia_janus_handle_call(Msg, _From, Janus) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_cast(Msg::term(), janus()) ->
    {ok, janus()}.

nkmedia_janus_handle_cast(Msg, Janus) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% @doc 
-spec nkmedia_janus_handle_info(Msg::term(), janus()) ->
    {ok, Janus::map()}.

nkmedia_janus_handle_info(Msg, Janus) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Janus}.


%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================


%% @private
nkmedia_session_event(SessId, {answer, Answer}, 
                      #{offer:=#{nkmedia_janus_proto:=in, pid:=Pid}}) ->
    #{sdp:=_} = Answer,
    lager:info("Janus (~s) calling media available", [SessId]),
    ok = nkmedia_janus_proto:answer(Pid, SessId, Answer),
    continue;


nkmedia_session_event(SessId, {hangup, _}, Session) ->
    case Session of
        #{offer:=#{nkmedia_janus_proto:=in, pid:=Pid1}} ->
            lager:info("Janus (~s) In captured hangup", [SessId]),
            nkmedia_janus_proto:hangup(Pid1, SessId);
        _ -> 
            ok
    end,
    case Session of
        #{answer:=#{nkmedia_janus_proto:=out, pid:=Pid2}} ->
            lager:info("Janus (~s) Out captured hangup", [SessId]),
            nkmedia_janus_proto:hangup(Pid2, SessId);
        _ ->
            ok
    end,
    continue;

nkmedia_session_event(_SessId, _Event, _Session) ->
    continue.


%% @private
nkmedia_session_invite(SessId, {nkmedia_janus_proto, Pid}, Offer, Session) ->
    case nkmedia_janus_proto:invite(Pid, SessId, Offer#{monitor=>self()}) of
        ok ->
            {ringing, #{nkmedia_janus_proto=>out, pid=>Pid}, Session};
        {error, Error} ->
            lager:warning("Error calling invite: ~p", [Error]),
            {rejected, <<"Janus Invite Error">>, Session}
    end;

nkmedia_session_invite(_SessId, _Dest, _Offer, _Session) ->
    continue.


% %% @private
nkmedia_call_resolve(Dest, Call) ->
    case nkmedia_janus_proto:find_user(Dest) of
        [Pid|_] ->
            {ok, {nkmedia_janus_proto, Pid}, Call};
        [] ->
            lager:info("Janus: user ~s not found", [Dest]),
            continue
    end.



%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(janus_listen, Url, _Ctx) ->
    Opts = #{valid_schemes=>[janus], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.


