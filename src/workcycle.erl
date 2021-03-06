-module(workcycle).
-compile([debug_info]).
-include_lib("stdlib/include/qlc.hrl").
-include("dc_server.hrl").
-behaviour(gen_fsm).

%% API
-export([join_workcycle/2,
		leave_workcycle/3,
		force_next_tick/0,
		get_passive_participant_list/0,
		register_participant/3,
		passive_participant_count/0,
		send_active_partlist/1,
		send_passive_partlist/1,
		set_rtmsg_timeout/1,
		set_tick_timeout/1,
		start_link/0,
		status/0,
		unregister_participant/1]).

%% gen_fsm callbacks
-export([init/1, 
		waiting/2,
		waiting/3,
		startup/2, 
		startup/3, 
		reservation/2, 
		reservation/3, 
		sending/2, 
		sending/3, 
		handle_event/3,
        handle_sync_event/4, 
		handle_info/3, 
		terminate/3, 
		code_change/4]).

-define(SERVER, ?MODULE).

-define(ACCEPTED, 0).
-define(REJECTED, 1).

-define(RESERVATION_LENGTH , 12).
-define(MODULO             , 16#100000000).

-define(WCN_GUARD, 50).

-record(init, {init = 0,
				initial_workcycle = 0}).

-record(state,{     %Needed for every state   
	   				current_workcycle                    = 0,
					participants_joining                 = [],
					participants_leaving                 = [],
					rtmsgtimeout                         = ?DEFAULTRTTIMEOUT,
					ticktimeout                          = ?DEFAULTTICKTIMEOUT,
					%Needed for reservation and sinding:
					add_up_msg                           = << 0:96 >>,
					current_round_number                 = 0,
					individual_message_lengths           = [],
					participants_expected                = [],
					participants_confirmed               = [],
					rounds_expected                      = -1
				}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------

get_passive_participant_list() ->
	gen_fsm:send_all_state_event(?MODULE, get_passive_participant_list).

passive_participant_count() ->
	gen_fsm:sync_send_all_state_event(?MODULE, count_passive_participants).

register_participant(Part, Controller, Peername) ->
	gen_fsm:send_all_state_event(?MODULE, {register, {Part, Controller, Peername}}).

send_active_partlist(Controller) ->
	gen_fsm:send_all_state_event(?MODULE, {send_active_partlist, Controller}).

send_passive_partlist(Controller) ->
	gen_fsm:send_all_state_event(?MODULE, {send_passive_partlist, Controller}).

unregister_participant(Part) ->
	gen_fsm:send_all_state_event(?MODULE, {unregister, Part}).

join_workcycle(Part, Controller) when 
						is_record(Part, participant) and is_pid(Controller) ->
	gen_fsm:send_event(?MODULE, {joinworkcycle, {Part, Controller}});		
join_workcycle(_, _) ->
	{error, badargs}.

leave_workcycle(Part, Controller, WCN) when is_record(Part, participant), 
							is_pid(Controller), is_integer(WCN)->
	gen_fsm:send_all_state_event(?MODULE, {leaveworkcycle, {Part, Controller, WCN}});
leave_workcycle(_, _, _) ->
	{error, badargs}.

force_next_tick() ->
	gen_fsm:send_all_state_event(?MODULE, {force_next_tick}),
	gen_fsm:send_event(?MODULE, start).

start_link() ->
  gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], []).

set_rtmsg_timeout(infinity) ->
	gen_fsm:send_all_state_event(?MODULE, {rtmsgtimeout, infinity}),
	ok;
set_rtmsg_timeout(Timeout) when is_integer(Timeout) ->
	gen_fsm:send_all_state_event(?MODULE, {rtmsgtimeout, Timeout}),
	ok.

set_tick_timeout(Timeout) when is_integer(Timeout) ->
	gen_fsm:send_all_state_event(?MODULE, {ticktimeout, Timeout}),
	ok.

status() ->
	gen_fsm:send_all_state_event(?MODULE, {status}),
	ok.

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to
%% initialize.
%%--------------------------------------------------------------------
init([]) ->
	workcycle_evt_mgr:start_link(),
	workcycle_evt_mgr:add_handler(workcycle_total_evt_hdlr),
	workcycle_evt_mgr:add_handler(workcycle_detailed_evt_hdlr),
	util:safe_mnesia_create_table( init, 
					[{disc_copies, [node()]}, 
								{attributes, record_info(fields, init)}]),
	T = fun() -> 
		RL = mnesia:read({init, 0}),
		case RL of
			[] -> -(?WCN_GUARD + 1);
			[I] -> I#init.initial_workcycle
		end
	end, 
	{atomic, Initial_wcn} = mnesia:transaction(T),
	util:safe_mnesia_create_table( participant_mgmt, 
					[{attributes, record_info(fields, participant_mgmt)}]),
	mnesia:add_table_index(articipant_mgmt, active_from),
	{ok, waiting, #state{current_workcycle = Initial_wcn + ?WCN_GUARD + 1,
							ticktimeout = config:get_tick_timeout()}}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName,
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also
%% called if a timeout occurs.
%%--------------------------------------------------------------------

waiting({joinworkcycle, {_Part, _Controller} = PartController}, State) ->
	io:format("[waiting]: new participant joining our workcycles~n"),
	NewPartJoining = [PartController | State#state.participants_joining], 
	NewState = State#state{participants_joining = NewPartJoining},
	CurrentWorkcycle = State#state.current_workcycle,
	AList = generic_get_active_participant_list(CurrentWorkcycle),
	case (length(AList) >= config:get_min_active_participants()) of
		true -> 
			%% this can not be true and we have to restart
			{next_state, waiting, #state{}};
		false ->
			case (length(NewPartJoining) + length(AList) >= config:get_min_active_participants()) of
				true -> 
						gen_fsm:send_event(?MODULE, start),
						{next_state, startup, NewState};
				false -> 
						{next_state, waiting, NewState}
			end
	end;

waiting(start, State) ->
	{next_state, waiting, State};

waiting(Event, State) ->
	io:format("[waiting]: event ~w is not for me~n", [Event]),
	{next_state, waiting, State}.


startup(start, State) ->
	CurrentWorkcycle = State#state.current_workcycle,
	workcycle_evt_mgr:notify({wc_start, CurrentWorkcycle, util:mk_timestamp_us()}),
	startup_test_and_store_wcn(CurrentWorkcycle),
	LPartConsL = generic_get_leaving_participant_list(CurrentWorkcycle),
	{LPartL, LConsL} = lists:unzip(LPartConsL),
	{JPartL, JConsL} = lists:unzip(State#state.participants_joining),
	APartConsL = generic_get_active_participant_list(CurrentWorkcycle),
	{APartL, AConsL} = lists:unzip(APartConsL),
	NExpdConsL = JConsL ++ AConsL -- LConsL,
	NExpdPartConsL = State#state.participants_joining ++ APartConsL -- LPartConsL,
	io:format("[startup]: WC ~w joining: ~w, this round leaving ~w, total participants ~w ~n", 
													[CurrentWorkcycle, JConsL, LConsL, NExpdConsL]),
	startup_send_w2wc(CurrentWorkcycle, APartL, JConsL),
	startup_send_iulp(LPartL, CurrentWorkcycle, NExpdConsL ++ LConsL),
	startup_set_participants_inactive(LPartL),
	startup_send_iujp(JPartL, CurrentWorkcycle, NExpdConsL),
	startup_set_participants_active(JPartL, CurrentWorkcycle),
	case length(NExpdPartConsL) >= config:get_min_active_participants() of
		true ->
			F = fun() ->
					receive 
						after State#state.ticktimeout ->
							true
					end,
					workcycle_evt_mgr:notify({res_start, CurrentWorkcycle, util:mk_timestamp_us()}),
					startup_send_tick(NExpdConsL, CurrentWorkcycle, State#state.rtmsgtimeout)
			end,
			spawn(F),
			ReservationState = #state{
				current_workcycle = State#state.current_workcycle,
				ticktimeout = State#state.ticktimeout,
				rtmsgtimeout = State#state.rtmsgtimeout,
				participants_expected=NExpdPartConsL, 
				participants_joining=[]},
			workcycle_evt_mgr:notify({count_active  , CurrentWorkcycle, length(NExpdConsL)}),
			workcycle_evt_mgr:notify({count_joining , CurrentWorkcycle, length(JConsL)}),
			workcycle_evt_mgr:notify({count_leaving , CurrentWorkcycle, length(LConsL)}),
			{next_state, reservation, ReservationState};
		false ->
			{next_state, waiting, #state{current_workcycle = CurrentWorkcycle +1, 
										rtmsgtimeout = State#state.rtmsgtimeout, 
										ticktimeout = State#state.ticktimeout}}
	end;

startup({joinworkcycle, {_Part, _Controller} = PartController}, State) ->
	io:format("[startup]: New participant joining our workcycles"),
	NewPartJoining = [PartController | State#state.participants_joining],
	NewState = State#state{participants_joining = NewPartJoining},
	{next_state, startup, NewState};

startup(Event, State) ->
	io:format("[startup]: Unknown event for state startup. Ignoring ~w!~n",[Event]),
	{next_state, startup, State}.


reservation({add, {part, P}, {con, C}, {wcn, W}, {rn, R}, {addmsg, <<AddMsg:96>>}}, State) 
		 		when 
				(W == State#state.current_workcycle) and 
				(R == State#state.current_round_number) ->
	io:format("[reservation]: Add message arrived for ~w ~w~n",[C,AddMsg]),
	Peername = generic_get_peername(P),
	workcycle_evt_mgr:notify({msg_arrived_res, W, R, Peername, 12, util:mk_timestamp_us()}),
	NLocalSum = generic_add_up_dcmsg(State#state.add_up_msg, <<AddMsg:96>>),
	NExpdPartConsL = lists:delete({P,C}, State#state.participants_expected),
	NConfPartConsL = [{P,C}| State#state.participants_confirmed],
	case length(NExpdPartConsL) == 0 of
		true -> 
			io:format("[reservation]: broadcast: ~w ~n", [NLocalSum]),
			AddedMsg = management_message:added(State#state.current_workcycle, 
											State#state.current_round_number, NLocalSum),
			{_, NConfConsL} = lists:unzip(NConfPartConsL),
			generic_send_to_participants(NConfConsL, AddedMsg),
			io:format("[reservation]: Checking if reservation has finished?~n"),
			case reservation_evaluate_reservation(State#state.rounds_expected, 
							State#state.individual_message_lengths, AddedMsg) of
				{not_finished} ->	%% Weitere Reservierungsrunde
					io:format("[reservation]: Not finished, just continuing~n"),
					NewState = State#state{
						add_up_msg             = << 0:96 >>,
						participants_expected  = NConfPartConsL,
						participants_confirmed = [],
						current_round_number   = State#state.current_round_number +1},
					generic_send_to_connections(NConfConsL, 
						{ 
						wait_for_realtime_msg, {wcn, W}, 
						{rn, R+1}, {timeout, State#state.rtmsgtimeout}}),
					{next_state, reservation, NewState};
				{not_finished, {ec,EC}} -> 
					io:format("[reservation]: Not finished, but at least we know how many rounds we are probably going to take: ~w~n",[EC]),
					NewState = State#state{
						add_up_msg             = << 0:96 >>,
						participants_expected  = NConfPartConsL,
						participants_confirmed = [],
						rounds_expected        = EC,
						current_round_number   = State#state.current_round_number +1},
					generic_send_to_connections(NConfConsL, 
						{ 
						wait_for_realtime_msg, {wcn, W}, 
						{rn, R+1}, {timeout, State#state.rtmsgtimeout}}),
					{next_state, reservation, NewState};
				{not_finished, {iml, IML}} ->
					io:format("[reservation]: Not finished, but there is at least one new message length collected.~n"),
					NewState = State#state{
						add_up_msg                 = << 0:96 >>,
						participants_expected      = NConfPartConsL,
						participants_confirmed     = [],
						individual_message_lengths = IML,
						current_round_number       = State#state.current_round_number +1},
					generic_send_to_connections(NConfConsL, 
						{ 
						wait_for_realtime_msg, {wcn, W}, 
						{rn, R+1}, {timeout, State#state.rtmsgtimeout}}),
					{next_state, reservation, NewState};
				{finished, {iml,[]}} -> %% Es gibt keine Teilnehmer -> neuer Workcycle
					io:format("Reservation finished - no participant wanted to send -> next workcycle~n"),
					workcycle_evt_mgr:notify({count_rounds, W, 0}),
					Now = util:mk_timestamp_us(),
					workcycle_evt_mgr:notify({res_stop, W, Now}),
					workcycle_evt_mgr:notify({send_start, W, Now}),
					workcycle_evt_mgr:notify({send_stop, W, Now}),
					workcycle_evt_mgr:notify({wc_stop, W, Now}),
					NewState = #state{
							current_workcycle     = W + 1,
							rtmsgtimeout          = State#state.rtmsgtimeout,
							ticktimeout           = State#state.ticktimeout,
							participants_expected = NConfPartConsL,
							participants_joining  = State#state.participants_joining,
							participants_leaving  = State#state.participants_leaving
						},
					gen_fsm:send_event(?MODULE, start),
					{next_state, startup, NewState};
				{finished, {iml, [NextMsgLengthBytes|RestMessages]}} ->
					io:format("Reservation finished -> next round~n"),
					workcycle_evt_mgr:notify({count_rounds, W, length([RestMessages]) + 1}),
					Now = util:mk_timestamp_us(),
					workcycle_evt_mgr:notify({res_stop, W, Now}),
					workcycle_evt_mgr:notify({send_start, W, Now}),
					generic_send_to_connections(NConfConsL, 
						{ 
						wait_for_realtime_msg, {wcn, W}, 
						{rn, R+1}, {timeout, State#state.rtmsgtimeout}}),
					NextMsgLengthBits = NextMsgLengthBytes * 8,	
					NewState = State#state{
						add_up_msg                 = <<0:NextMsgLengthBits>>,
						current_round_number       = R + 1,
						participants_expected      = NConfPartConsL,
						participants_confirmed     = [],
						individual_message_lengths = RestMessages},
					{next_state, sending, NewState}
			end;
		_ ->
			{next_state, reservation, State#state{add_up_msg = NLocalSum, 
											participants_expected = NExpdPartConsL, 
											participants_confirmed = NConfPartConsL}}
	end;

reservation({addtimeout, {part, P}, {con, _C}, {wcn, _W}, {rn, _R}}, State) ->
	gen_fsm:send_all_state_event(?MODULE, {unregister, P}), 
	{next_state, reservation, State};

reservation({joinworkcycle, {_Part, _Controller} = PartController}, State) ->
	io:format("[reservation]: new participant joining our workcycles~n"),
	NewPartJoining = [PartController | State#state.participants_joining],
	NewState = State#state{participants_joining = NewPartJoining},
	{next_state, reservation, NewState};

reservation(start, State) ->
	{next_state, reservation, State};

reservation(Event, State) ->
	io:format("[reservation]: dont know how to handle event ~w in state ~w~n",[Event, State]),
	{next_state, reservation, State}.

sending({add, {part, P}, {con, C}, {wcn, W}, {rn, R}, {addmsg, AddMsg}}, State)
		 		when 
				is_binary(AddMsg) and
				(size(AddMsg) == size(State#state.add_up_msg)) and
				(W == State#state.current_workcycle) and 
				(R == State#state.current_round_number) ->
	%io:format("[sending]: Add message arrived for ~w ~n",[C]),
	Peername = generic_get_peername(P),
	workcycle_evt_mgr:notify({msg_arrived, W, R, Peername, size(AddMsg), util:mk_timestamp_us()}),
	NLocalSum = generic_add_up_dcmsg(State#state.add_up_msg, AddMsg),
	NExpdPartConsL = lists:delete({P,C}, State#state.participants_expected),
	NConfPartConsL = [{P,C}| State#state.participants_confirmed],
	case length(NExpdPartConsL) == 0 of
		true -> 
			io:format("[sending]: broadcast ~n"),
			%io:format("[sending]: broadcast ~w~n", [NLocalSum]),
			AddedMsg = management_message:added(State#state.current_workcycle, 
											State#state.current_round_number, NLocalSum),
			%io:format("[sending]: Unzipping lists~n"),
			{_, NConfConsL} = lists:unzip(NConfPartConsL),
			%io:format("[sending]: distributing added message~n"),
			generic_send_to_participants(NConfConsL, AddedMsg),
			%io:format("[sending]: Checking whether workcycle has finished..."),
			case length(State#state.individual_message_lengths) of
				0 ->
					%io:format("...yup: no more new messages, starting new workcycle"),
					NState = #state{ current_workcycle    = W + 1,
									rtmsgtimeout          = State#state.rtmsgtimeout,
									ticktimeout           = State#state.ticktimeout,
									participants_expected = NConfPartConsL,
									participants_joining  = State#state.participants_joining,
									participants_leaving  = State#state.participants_leaving
										},
					gen_fsm:send_event(?MODULE, start),
					Now = util:mk_timestamp_us(),
					workcycle_evt_mgr:notify({send_stop, W, Now}),
					workcycle_evt_mgr:notify({wc_stop, W, Now}),
					{next_state, startup, NState};
				_L ->
					%io:format("... nope: there are ~w further rounds expectd~n",[L]),
					[NextMsgLengthBytes| RestMsgL] = State#state.individual_message_lengths,
					NextMsgLengthBits = NextMsgLengthBytes *8,
					NState = State#state{   individual_message_lengths = RestMsgL,
											add_up_msg = <<0:NextMsgLengthBits>>,
											current_round_number = R + 1,
											participants_confirmed = [],
											participants_expected = NConfPartConsL
										},
					generic_send_to_connections(NConfConsL, 
						{ 
						wait_for_realtime_msg, {wcn, W}, 
						{rn, R+1}, {timeout, State#state.rtmsgtimeout}}),
					{next_state, sending, NState}
			end;
		false ->
			NState = State#state{   add_up_msg = NLocalSum,
									participants_confirmed = NConfPartConsL,
									participants_expected = NExpdPartConsL},
			{next_state, sending, NState}
	end;

sending({joinworkcycle, {_Part, _Controller} = PartController}, State) ->
	io:format("[sending]: new participant joining our workcycles~n"),
	NewPartJoining = [PartController | State#state.participants_joining],
	NewState = State#state{participants_joining = NewPartJoining},
	{next_state, sending, NewState};

sending({addtimeout, {part, P}, {con, _C}, {wcn, _W}, {rn, _R}}, State) ->
	gen_fsm:send_all_state_event(?MODULE, {unregister, P}), 
	{next_state, sending, State};

sending(start, State) ->
	{next_state, sending, State};

sending(Event, State) ->
	io:format("[sending]: don't know propper reaction for ~w in ~w state~n", [Event, State]),
	{next_state, sending, State}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName,
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName,
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------
waiting(_Event, _From, State) ->
  Reply = ok,
  {reply, Reply, waiting, State}.

startup(_Event, _From, State) ->
  Reply = ok,
  {reply, Reply, startup, State}.

reservation(_Event, _From, State) ->
  Reply = ok,
  {reply, Reply, reservation, State}.

sending(_Event, _From, State) ->
  Reply = ok,
  {reply, Reply, reservation, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, StateName, State) -> {next_state, NextStateName,
%%                                                NextState} |
%%                                          {next_state, NextStateName,
%%                                                NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------

handle_event({force_next_tick}, StateName, State) ->
	io:format("[force_next_tick]: Switching from ~w to startup~n",[StateName]),
	CWN = State#state.current_workcycle,
	NState = #state{current_workcycle = CWN +1,
					participants_joining = State#state.participants_joining,
					participants_leaving = State#state.participants_leaving,
					rtmsgtimeout = State#state.rtmsgtimeout,
					ticktimeout = State#state.ticktimeout },
	{next_state, startup, NState};

handle_event({leaveworkcycle, {Part, _Controller, WCN}}, StateName, State) ->
	CurrentWCN = State#state.current_workcycle,
	F = fun() ->
			E = mnesia:read(participant_mgmt, Part, write),
			case E of
				[] -> 
					mnesia:abort(no_actual_participant);
				[PMI] ->
					case (PMI#participant_mgmt.active_from =< CurrentWCN) 
						and (PMI#participant_mgmt.active_from >= 0)
						and (PMI#participant_mgmt.active_until < 0)
						and (WCN >= CurrentWCN + 1) of
						true -> 
							mnesia:write(PMI#participant_mgmt{active_until = WCN});
						false -> 
							mnesia:abort(no_active_participant)
					end
			end
		end,
	mnesia:transaction(F),
	{next_state, StateName, State};

handle_event({register, {Part, Controller, Peername}}, StateName, State) when is_record(Part, participant) ->
	T = fun() ->
		R = mnesia:wread({participant_mgmt, Part}),
		case R of
			[] -> 
				M = management_message:accepted4service(true),
				Controller ! {forward_to_participant, {msg,M}},
				PMI = #participant_mgmt{ participant = Part, controller = Controller, peername = Peername},
				mnesia:write(PMI),
				ok;
			_E -> 
				io:format("[registration]: there already is such a participant~n"),
				mnesia:abort(participant_already_registered)
		end
		end,
	case mnesia:transaction(T) of
		{atomic, ok} -> 
			{next_state, StateName, State};
		_ -> 
			Controller ! {close_socket_immediately},
			{next_state, StateName, State}
	end;

handle_event({rtmsgtimeout, Timeout}, StateName, State) ->
	NState = State#state{rtmsgtimeout = Timeout},
	{next_state, StateName, NState};

handle_event({unregister, Part}, StateName, State) when is_record(Part, participant) ->
	CWN = State#state.current_workcycle,
	case generic_is_participant_active(Part, CWN) of
		true -> 
			io:format("[handle_event][unregister participant]: Participant is active~n"),
			APartConL = generic_get_active_participant_list(CWN),
			{_APartL, AConL} = lists:unzip(APartConL),
			io:format("[handle_event][unregister participant]: Sending info early quit to ~w~n", 
				[AConL]),
			generic_send_info_early_quit_service(Part, CWN, State#state.current_round_number, AConL),
			generic_unregister_passive_participant(Part),
			NState = #state{current_workcycle = CWN +1,
							rtmsgtimeout = State#state.rtmsgtimeout,
							ticktimeout = State#state.ticktimeout,
							participants_joining = State#state.participants_joining,
							participants_leaving = State#state.participants_leaving
							},
			gen_fsm:send_event(?MODULE, start),
			{next_state, startup, NState};
		false -> 
			io:format("[handle_event][unregister participant]: Participant is not active~n"),
			generic_unregister_passive_participant(Part),
			{next_state, StateName, State}
	end;

handle_event({send_passive_partlist, Controller}, StateName, State) ->
	PartList = mnesia:dirty_all_keys(participant_mgmt),
	Msg = management_message:info_passive_partlist(PartList),
	Controller ! {forward_to_participant, {msg, Msg}},
	{next_state, StateName, State};	

handle_event({status}, StateName, State) ->
	LenConf = length(State#state.participants_confirmed),
	LenExptd = length(State#state.participants_expected),
	{_, ExptdCons} = lists:unzip(State#state.participants_expected),
	LenJoining = length(State#state.participants_joining),
	LenLeaving = length(State#state.participants_leaving),
	io:format("[status]: Current WCN: ~w~n[status]: Current round: ~w
[status]: Participants joining: ~w~n[status]: Participants  leaving: ~w
[status]: Participants expected: ~w (~w)~n[status]: Participants confirmed: ~w~n
[status]: state name: ~w~n", 
		[State#state.current_workcycle, State#state.current_round_number, 
			LenJoining, LenLeaving, LenExptd, ExptdCons, LenConf, StateName]),
	{next_state, StateName, State};

handle_event({ticktimeout, Timeout}, StateName, State) ->
	NState = State#state{ticktimeout = Timeout},
	{next_state, StateName, NState};

handle_event(_Event, StateName, State) ->
  {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_sync_event(Event, From, StateName,
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState,
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState,
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------

handle_sync_event(count_passive_participants, _From, StateName, State) ->
	Reply = mnesia:table_info(participant_mgmt, size),
	{reply, Reply, StateName, State};

handle_sync_event(_Event, _From, StateName, State) ->
  Reply = ok,
  {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState,
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
  {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
  ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

generic_send_to_participants([], _Msg) ->
	ok;
generic_send_to_participants(ConList, Msg) when is_list(ConList) ->
	%io:format("[generic_send]: send arguemtns received: ~w ~w~n",[PartConList, Msg]),
	lists:foreach( fun(X) -> 
				%io:format("forwarding ~w to ~w~n",[Msg, X]),
				X ! {forward_to_participant, {msg, Msg}} end, ConList),
	ok;
generic_send_to_participants(_PList, _Msg) ->
	ok.

generic_send_to_connections([], _Msg) ->
	ok;
generic_send_to_connections(ConsL, Msg) when is_list(ConsL) ->
	lists:foreach( fun(X) -> 
				X ! Msg end, ConsL),
	ok;
generic_send_to_connections(_PList, _Msg) ->
	ok.

generic_add_up_dcmsg(A,B) ->
	generic_add_up_dcmsg(A, B, []).

generic_add_up_dcmsg(<<AH:32, AT/binary>>, <<BH:32, BT/binary>>, CList)->
	Remainder= (AH + BH) rem ?MODULO,
	generic_add_up_dcmsg(AT, BT, [<<Remainder:32>> | CList]);
generic_add_up_dcmsg(<<>>, <<>>, CList) ->
	RList = lists:reverse(CList),
	list_to_binary(RList).

generic_get_active_participant_list(CurrentWorkcycle) ->
	AT = fun() ->
			qlc:e(
				qlc:q([ {X#participant_mgmt.participant, X#participant_mgmt.controller} || 
									X <- mnesia:table(participant_mgmt), 
									X#participant_mgmt.active_from =< CurrentWorkcycle,
									X#participant_mgmt.active_from >= 0
									]))
		end,
	{atomic, AList} = mnesia:transaction(AT),
	AList.

generic_get_leaving_participant_list(CurrentWorkcycle) ->
	AT = fun() ->
			qlc:e(
				qlc:q([ {X#participant_mgmt.participant, X#participant_mgmt.controller} || 
									X <- mnesia:table(participant_mgmt), 
									X#participant_mgmt.active_until == CurrentWorkcycle
									]))
		end,
	{atomic, LList} = mnesia:transaction(AT),
	LList.

generic_get_peername(Part) ->
	PT = fun() ->
			mnesia:read(participant_mgmt, Part, read)
		end,
	case mnesia:transaction(PT) of 
		{atomic, []} ->
			undefined;
		{atomic, [PMI]} ->
			PMI#participant_mgmt.peername;
		_Error ->
			undefined
	end.

generic_is_participant_active(Participant, CurrentWorkcycle) ->
	AT = fun() ->
			mnesia:read(participant_mgmt, Participant, read)
		end,
	case mnesia:transaction(AT) of 
		{atomic, []} ->
			false;
		{atomic, [PMI]} ->
			case (PMI#participant_mgmt.active_from =< CurrentWorkcycle) and
				(PMI#participant_mgmt.active_from >= 0) of
				true -> true;
				false -> false
			end;
		_F	-> false
	end.

generic_send_info_early_quit_service(LeavingPart, Workcycle, RoundNumber, ExpectedConsL) ->
	IEQS = management_message:info_early_quit_service([LeavingPart], Workcycle, RoundNumber),
	generic_send_to_participants(ExpectedConsL, IEQS),
	ok.

generic_unregister_passive_participant(Part) ->
	T = fun() ->
			mnesia:delete({participant_mgmt, Part})
		end,
	case mnesia:transaction(T) of
		{atomic, ok} ->
			io:format("[unregister]: Unregistered participant~n");
		Error ->
			io:format("[unregister] ~p~n",[Error])
	end.

startup_send_iujp(_JP, _CurrentWorkcycle, []) -> ok;
startup_send_iujp([], _CurrentWorkcycle, _ExptConsL) -> ok;
startup_send_iujp(JPartL, CurrentWorkcycle, ExptConsL) ->
	IUJMsg = management_message:info_update_joining_participants(JPartL, CurrentWorkcycle),
	generic_send_to_participants(ExptConsL, IUJMsg),
	ok.

startup_send_iulp(_LP, _CurrentWorkcycle, []) -> ok;
startup_send_iulp([], _CurrentWorkcycle, _ExptConsL) -> ok;
startup_send_iulp(LPartL, CurrentWorkcycle, ExptConsL) ->
	IULMsg = management_message:info_update_leaving_participants(LPartL, CurrentWorkcycle),
	generic_send_to_participants(ExptConsL, IULMsg),
	ok.

% TODO edit timeout.
startup_send_w2wc(_C, _A, []) -> ok;
startup_send_w2wc(CurrentWorkcycle, APartL, JConsL) ->
	W2WMsg = management_message:welcome2workcycle(?ACCEPTED, 
										CurrentWorkcycle, 2000, APartL),
	generic_send_to_participants(JConsL, W2WMsg),
	ok.

startup_send_tick([], _CurrentWorkcycle, _RTtimeout) -> ok;
startup_send_tick(ExpdConsL, CurrentWorkcycle, RTtimeout) ->
	TickMsg = management_message:tick(CurrentWorkcycle),	
	generic_send_to_connections(ExpdConsL, 
		{ 
		wait_for_realtime_msg, {wcn, CurrentWorkcycle}, 
		{rn, 0}, {timeout, RTtimeout}
	}),
	generic_send_to_participants(ExpdConsL, TickMsg),
	ok.

startup_set_participants_active([], _) ->
	ok;
startup_set_participants_active(PartList, ForWhichWorkcycle) ->
	SAT = fun() ->
				PartRecs = lists:flatmap(fun(X) -> 
									 	mnesia:read({participant_mgmt, X})
									end, PartList),
				lists:foreach(fun(X) ->
								NPMI = X#participant_mgmt{active_from=ForWhichWorkcycle},
								mnesia:write(NPMI) end, 
								PartRecs) 
			end,
	case mnesia:transaction(SAT) of
		{atomic, ok} -> ok;
		Error -> 
			io:format("[startup_set_participants_active]: There was something wrong with setting the participant active ~w~n",
				[Error]),
			false
	end.

startup_set_participants_inactive([]) ->
	ok;
startup_set_participants_inactive(PartList) ->
	SAT = fun() ->
				PartRecs = lists:flatmap(fun(X) -> 
									 	mnesia:read({participant_mgmt, X})
									end, PartList),
				lists:foreach(fun(X) ->
								NPMI = X#participant_mgmt{active_from=-1, active_until=-1},
								mnesia:write(NPMI) end, 
								PartRecs) 
			end,
	case mnesia:transaction(SAT) of
		{atomic, ok} -> ok;
		Error -> 
			io:format("[startup_set_participants_inactive]: There was something wrong with setting the participant active ~w~n",
				[Error]),
			false
	end.

startup_test_and_store_wcn(WCN) when (WCN rem ?WCN_GUARD) =:= 0 ->
	T = fun() ->
			mnesia:write(#init{ initial_workcycle = WCN})
	end,
	mnesia:transaction(T);
startup_test_and_store_wcn(_WCN) ->
	ok.

reservation_evaluate_reservation(-1, _IndividualMessageLengths , <<_:112, 1:32, IndividualMessageLength:32, _Random:32>>) ->
	{finished, {iml, [IndividualMessageLength]}};
reservation_evaluate_reservation(-1, _Confirmed , <<_:112, 0:32, _IndividualLength:32, _Random:32>>) ->
	{finished, {iml,[]}};
reservation_evaluate_reservation(ExpectedRounds, IndividualMessageLengths, <<_:112, 1:32, IndividualMessageLength:32, _Random:32>>) 
	when length(IndividualMessageLengths) == (ExpectedRounds - 1) ->
	{finished, {iml,lists:reverse([IndividualMessageLength|IndividualMessageLengths])}};
reservation_evaluate_reservation(_ExpectedRounds, IndividualMessageLengths, <<_:112, 1:32, IndividualMessageLength:32, _Random:32>>) ->
	{not_finished, {iml,[IndividualMessageLength|IndividualMessageLengths]}};
reservation_evaluate_reservation(-1, _IndividualMessageLengths , <<_:112, ParticipantCount:32, _IndividualLength:32, _Random:32>>) ->
	{not_finished, {ec,ParticipantCount}};
reservation_evaluate_reservation(ExpectedRounds, _IndividualMessageLengths , <<_:112, ParticipantCount:32, _IndividualLength:32, _Random:32>>) when (ExpectedRounds > ParticipantCount) ->
	{not_finished};
reservation_evaluate_reservation(ExpectedRounds, IndividualMessageLengths, AddMsg) ->
	io:format("[reservation_evaluator]: Error: Expr ~w, Indiv ~w, Addm ~w~n", 
		[ExpectedRounds, IndividualMessageLengths, AddMsg]),
	_ = io:get_line("reservation_evaluator:"),
	timer:sleep(100),
	{not_finished}.
