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
-module(nkmedia_sip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([find_registered/3, send_invite/4, send_hangup/1]).

-define(LLOG(Type, Txt, Args),
    lager:Type("NkMEDIA SIP Plugin (~s) "++Txt, [SessId|Args])).


% -define(OP_TIME, 15000).            % Maximum operation time
% -define(CALL_TIMEOUT, 30000).       % 


%% ===================================================================
%% Types
%% ===================================================================

-type invite_opts() ::
	#{
		body => binary(),
		from => nklib:user_uri(),
		pass => binary(),
		route => nklib:user_uri()
	}.



%% ===================================================================
%% Public
%% ===================================================================



find_registered(SrvId, User, Domain) ->
    nksip_registrar:find(SrvId, sip, User, Domain).
    


%% @private
-spec send_invite(nkservice:id(), nkmedia_session:id(),
                  nklib:user_uri(), invite_opts()) ->
	ok.

send_invite(SrvId, SessId, Uri, Opts) ->
    Self = self(),
    Fun = fun({resp, Code, Resp, _Call}) -> 
        if
            Code==180; Code==183 ->
                {ok, Body} = nksip_response:body(Resp),
                case nksip_sdp:is_sdp(Body) of
                    true ->
                        SDP = nksip_sdp:unparse(Body),
                        nkmedia_session:invite_reply(SessId, {ringing, #{sdp=>SDP}});
                    false ->
                        nkmedia_session:invite_reply(SessId, ringing)
                end;
            Code < 200 -> 
                ok;
            Code >= 300 -> 
                nkmedia_session:hangup(SessId, Code);
            true ->
                {ok, Dialog} = nksip_dialog:get_handle(Resp),
                %% We are storing this in the session's process (Self)
                nklib_proc:put({?MODULE, dialog, Dialog}, SessId, Self),
                nklib_proc:put({?MODULE, session, SessId}, Dialog, Self),
                {ok, Body} = nksip_response:body(Resp),
                case nksip_sdp:is_sdp(Body) of
                    true ->
                        Answer = #{sdp=>nksip_sdp:unparse(Body)},
                        case nkmedia_session:invite_reply(SessId, {answered, Answer}) of
                            ok ->
                                ok;
                            Other ->
                                ?LLOG(warning, "error calling session answer: ~p", 
                                      [Other]),
                                spawn(fun() -> nksip_uac:bye(Dialog, []) end)
                        end;
                    false ->
                        ?LLOG(notice, "missing SDP in response", []),
                        spawn(fun() -> nksip_uac:bye(Dialog, []) end)
                end
        end
    end,
    ?LLOG(info, "calling ~s", [nklib_unparse:uri(Uri)]),
    InvOpts1 = [async, {callback, Fun}, auto_2xx_ack],
    InvOpts2 = case Opts of
        #{sdp:=SDP} -> 
            SDP2 = nksip_sdp:parse(SDP),
            [{body, SDP2}|InvOpts1];
        _ -> 
            InvOpts1
    end,
    InvOpts3 = case Opts of
        #{from:=From} -> [{from, From}|InvOpts2];
        _ -> InvOpts2
    end,
    InvOpts4 = case Opts of
        #{pass:=Pass} -> [{sip_pass, Pass}|InvOpts3];
        _ -> InvOpts3
    end,
    InvOpts5 = case Opts of
        #{proxy:=Proxy} -> [{route, Proxy}|InvOpts4];
        _ -> InvOpts4
    end,
    {async, Handle} = nksip_uac:invite(SrvId, Uri, InvOpts5),
    nklib_proc:put({?MODULE, cancel, SessId}, Handle),
    ok.



%% @private
send_hangup(SessId) ->
    case nklib_proc:values({?MODULE, session, SessId}) of
        [{Dialog, _SessPid}|_] ->
            nksip_uac:bye(Dialog, []);
        [] ->
            case nklib_proc:values({?MODULE, cancel, SessId}) of
                [{Handle, _SessPid}|_] ->
                    nksip_uac:cancel(Handle, []);
                [] ->
                    lager:notice("Sending Hangup for unknown SIP")
            end
    end.
