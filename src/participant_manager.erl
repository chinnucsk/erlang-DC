%%%-------------------------------------------------------------------
%%% File    : eb_server.erl
%%% Author  : Mitchell Hashimoto <mitchell.hashimoto@gmail.com>
%%% Description : The ErlyBank account server.
%%%
%%% Created :  5 Sep 2008 by Mitchell Hashimoto <mitchell.hashimoto@gmail.com>
%%%-------------------------------------------------------------------
-module(participant_manager).
-include("dc_server.hrl").
-behaviour(gen_server).


%% API
-export([get_passive_participant_list/0,
		register_participant/2,
		passive_participant_count/0,
		send_active_partlist/1,
		send_passive_partlist/1,
		start_link/0,
		unregister_participant/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
get_passive_participant_list() ->
	gen_server:call(?MODULE, get_passive_participant_list).

passive_participant_count() ->
	gen_server:call(?MODULE, count_passive_participants).

register_participant(Part, Controller) ->
	gen_server:cast(?MODULE, {register, {Part, Controller}}).

send_active_partlist(Controller) ->
	gen_server:cast(?MODULE, {send_active_partlist, Controller}).

send_passive_partlist(Controller) ->
	gen_server:cast(?MODULE, {send_passive_partlist, Controller}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

unregister_participant(Part) ->
	gen_server:cast(?MODULE, {unregister, Part}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init(_) ->
	mnesia:create_table(participant_mgmt, 
		[{attributes, record_info(fields,participant_mgmt)}]),
	mnesia:add_table_index(participant_mgmt, active_from),
	{ok, state}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call(count_passive_participants, _From, State) ->
	Reply = mnesia:table_info(participant_mgmt, size),
	{reply, Reply, State};

handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------

handle_cast({register, {Part, Controller}}, State) when is_record(Part, participant) ->
	M = management_message:accepted4service(true),
	Controller ! {forward_to_participant, {msg,M}},
	%gen_tcp:send(Sock, M),
	PMI = #participant_mgmt{ participant = Part, controller = Controller },
	T = fun() ->
		mnesia:write(PMI),
		ok
		end,
	case mnesia:transaction(T) of
		{atomic, ok} -> 
			{noreply, State};
		_ -> io:format("Problems while registering~n"),
			{noreply, State}
	end;

handle_cast({unregister, Part}, State) when is_record(Part, participant) ->
	T = fun() ->
			mnesia:delete({participant_mgmt, Part})
		end,
	case mnesia:transaction(T) of
		{atomic, ok} ->
			io:format("Unregistered a participant~n");
		Error ->
			io:format("~p~n",[Error])
	end,
	{noreply, State};

handle_cast({send_passive_partlist, Controller}, State) ->
	PartList = mnesia:dirty_all_keys(participant_mgmt),
	Msg = management_message:info_passive_partlist(PartList),
	Controller ! {forward_to_participant, {msg, Msg}},
	{noreply, State};	

handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
