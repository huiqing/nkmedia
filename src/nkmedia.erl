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

-module(nkmedia).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export_type([offer/0, answer/0, hangup_reason/0]).
-export_type([engine_id/0, engine_config/0]).

%% ===================================================================
%% Types
%% ===================================================================


-type offer() ::
	#{
		sdp => binary(),
		sdp_type => rtp | webrtc,
		dest => binary(),
        caller_name => binary(),
        caller_id => binary(),
        callee_name => binary(),
        callee_id => binary(),
        use_audio => boolean(),
        use_stereo => boolean(),
        use_video => boolean(),
        use_screen => boolean(),
        use_data => boolean(),
        in_bw => integer(),
        out_bw => integer(),
        pid => pid(),				% if included, will be monitorized
        module() => term()
	}.


-type answer() ::
	#{
		sdp => binary(),
		sdp_type => rtp | webrtc,
		verto_params => map(),
        use_audio => boolean(),
        use_video => boolean(),
        use_data => boolean(),
        pid => pid(),				% if included, will be monitorized
        module() => term()
	}.


-type hangup_reason() :: nkmedia_util:hangup_reason().


-type engine_id() :: binary().


-type engine_config() ::
	#{
		srv_id => nkservice:id(),		% Service Id
		name => binary(),				% Engine Id (docker name)
		comp => binary(),				% Docker Company
		vsn => binary(),				% Version
		rel => binary(),				% Release
		host => binary(),				% Host
		pass => binary(),				% Pass		
		base => integer()				% Base Port
	}.



%% ===================================================================
%% Public functions
%% ===================================================================
