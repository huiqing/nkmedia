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

%% @doc Plugin implementing a SIP server and client
-module(nkmedia_sip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_sip_call/2]).
-export([sip_get_user_pass/4, sip_authorize/3]).
-export([sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_bye/2]).
-export([nkmedia_session_invite/4, nkmedia_session_event/3]).


%% ===================================================================
%% Types
%% ===================================================================


-type continue() :: continue | {continue, list()}.




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nksip].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA SIP (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-spec nkmedia_sip_call(nkmnedia_session:id(), nkmedia:offer()) ->
    ok | {rejected, nkmedia:hangup_reason()} | continue().

nkmedia_sip_call(_SessId, _Offer) ->
    {rejected, <<"Not Implemented">>}.



%% ===================================================================
%% Implemented Callbacks - nksip
%% ===================================================================

%% @private
sip_get_user_pass(_User, _Realm, _Req, _Call) ->
    true.


%% @private
sip_authorize(_AuthList, _Req, _Call) ->
    ok.


%% @private
sip_invite(Req, Call) ->
    SrvId = nksip_call:srv_id(Call),
    {ok, AOR} = nksip_request:meta(aor, Req),
    {ok, Body} = nksip_request:meta(body, Req),
    HasSDP = nksip_sdp:is_sdp(Body),
    case AOR of
        {sip, User, Domain} when HasSDP ->
            SDP = nksip_sdp:unparse(Body),
            {ok, Handle} = nksip_request:get_handle(Req),
            {ok, Dialog} = nksip_dialog:get_handle(Req),
            Offer = #{
                dest => <<User/binary, $@, Domain/binary>>,
                sdp => SDP, 
                sdp_type => rtp, 
                % direction => in,
                nkmedia_sip => {in, Handle, Dialog}, 
                pid => self()
            },
            {ok, SessId, _SessPid} = nkmedia_session:start(SrvId, #{offer=>Offer}),
            lager:notice("NkMEDIA SIP call to ~s@~s (~p, ~s)", 
                         [User, Domain, self(), SessId]),
            nklib_proc:put({nkmedia_sip, dialog, Dialog}, SessId),
            nklib_proc:put({nkmedia_sip, cancel, Handle}, SessId),
            case SrvId:nkmedia_sip_call(SessId, Offer) of
                ok ->
                    noreply;
                {rejected, Reason} ->
                    nkmedia_session:hangup(SessId, {hangup, Reason}),
                    {reply, decline}
            end;
        _ ->
            {reply, decline}
    end.


%% @private
sip_reinvite(_Req, _Call) ->
    {reply, decline}.


%% @private
sip_cancel(InviteReq, _Request, _Call) ->
    {ok, Handle} = nksip_request:get_handle(InviteReq),
    case nklib_proc:values({nkmedia_sip, cancel, Handle}) of
        [{SessId, _}|_] ->
            nkmedia_session:hangup(SessId, <<"Sip Cancel">>),
            ok;
        [] ->
            ok
    end.


%% @private Called when a BYE is received from SIP
sip_bye(Req, _Call) ->
	{ok, Dialog} = nksip_dialog:get_handle(Req),
    case nklib_proc:values({nkmedia_sip, dialog, Dialog}) of
        [{SessId, _SessPid}] ->
            nkmedia_session:hangup(SessId);
        [] ->
            lager:notice("Received SIP BYE for unknown session")
    end,
	continue.



%% ===================================================================
%% Implemented Callbacks - nkmedia
%% ===================================================================


%% @private
nkmedia_session_event(_SessId, {answer, Answer}, 
                      #{offer:=#{nkmedia_sip:={in, Handle, _Dialog}}}) ->
    #{sdp:=SDP1} = Answer,
    lager:info("SIP calling media available"),
    SDP2 = nksip_sdp:parse(SDP1),
    ok = nksip_request:reply({answer, SDP2}, Handle),
    continue;

nkmedia_session_event(_SessId, {hangup, _}, 
                      #{offer:=#{nkmedia_sip:={in, _Handle, Dialog}}}) ->
    spawn(fun() -> nksip_uac:bye(Dialog, []) end),
    continue;

nkmedia_session_event(SessId, {hangup, _}, 
                      #{answer:=#{nkmedia_sip:=out}}) ->
    nkmedia_sip:send_hangup(SessId),
    continue;

nkmedia_session_event(_SessId, _Event, _Session) ->
    continue.


%% @private
nkmedia_session_invite(SessId, {nkmedia_sip, Uri, Opts}, Offer, Session) ->
    #{srv_id:=SrvId} = Session,
    case Offer of
        #{sdp_type:=rtp, sdp:=SDP} ->
            ok = nkmedia_sip:send_invite(SrvId, SessId, Uri, Opts#{sdp=>SDP}),
            {async, #{nkmedia_sip=>out}, Session};
        _ ->
            {rejected, <<"Invalid SIP SDP">>, Session}
    end;

nkmedia_session_invite(_SessId, _Dest, _Offer, _Session) ->
	continue.






