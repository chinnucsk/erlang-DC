-module(connection).
-include("dc_server.hrl").
-export([welcome/1]).

welcome(Sock) ->
	NumPart = participant_manager:passive_participant_count(),
	W2M = management_message:welcome2service(?PROTOCOL_VERSION, ?SYMBOL_LENGTH,NumPart, 0, ?FEATURE_LIST),
	case gen_tcp:send(Sock, W2M) of
		ok -> 
			case gen_tcp:recv(Sock, 2, 2000) of
				{ok, MsgTypeBin} ->
					case gen_tcp:recv(Sock, 2, 100) of
						{ok, LengthBin} ->
							<<Length:16/integer-signed>> = LengthBin,
								case gen_tcp:recv(Sock, Length, 100) of
									{ok, MsgBin} -> 
										{register_at_service, Part} = management_message:parse_message(MsgTypeBin, MsgBin),
										participant_manager:register_participant(Part, self()),
										AMHPid = spawn_link(rt_message_handler, rt_message_handler, [{wait, 
													{part, Part}, {con, self()}, {wcn, -1},{bufferlist,[]}}]),
										listen(Sock, Part, AMHPid, <<>>),
										ok;
									{error,Reason} -> {error, Reason}       
								end;
						{error, Reason} -> {error, Reason}
					end;
					{error, Reason} -> {error, Reason}
				end,
				ok;
		{error, Reason} -> 
			gen_tcp:close(Sock),
			{error, Reason}
	end.

listen(Sock, Part, RTMsgHndlr, IncompleteMessage) ->
	inet:setopts(Sock,[{active,once}, {keepalive, true}]),
	receive
		{tcp_closed,Sock} ->
			io:format("Socket closed, unregistering participant~n"),
			participant_manager:unregister_participant(Part),
			ok;
		{tcp, Sock, Data} ->
			IncompleteMessage = construct_and_parse_messages(Sock, Part, RTMsgHndlr, IncompleteMessage, Data),
			listen(Sock,Part, RTMsgHndlr, IncompleteMessage);
		%% Messages from other processes to forward to the socket
		{forward_to_participant, {msg,Msg}} when is_binary(Msg)->
			gen_tcp:send(Sock, Msg),
			listen(Sock, Part, RTMsgHndlr, IncompleteMessage);

		{wait_for_realtime_msg,
			{wcn, WC}, {rn, RN}, {timeout, Timeout}} ->
			RTMsgHndlr ! {wait_for_realtime_msg,
									{wcn, WC}, {rn, RN}, {timeout, Timeout}},
			listen(Sock, Part, RTMsgHndlr, IncompleteMessage);

		Error ->
			io:format("Arbritrary message on Socket ~w: ~w~n", [Sock, Error]),
			listen(Sock,Part, RTMsgHndlr, IncompleteMessage)
	end.

construct_and_parse_messages(_Sock, _Part, _RTMsgHndlr, OldDataBin, <<>>) ->
	OldDataBin;
construct_and_parse_messages(Sock, Part, RTMsgHndlr, <<>>, <<MsgType:16, MsgLen:16, MsgBin:MsgLen/binary, Rest/binary>>) ->
	case management_message:parse_message(<<MsgType:16>>, MsgBin) of
		{irq, Irq} -> 
			handle_irq(Irq);
		{joinworkcycle} -> 
			workcycle:join_workcycle(Part, self());
		{add, WCN, RN, AddMsg} ->
			%io:format("Addmessage arrived: ~w ~n",[AddMsg]),
			RTMsgHndlr ! {add, {part, Part}, {wcn, WCN}, {rn, RN}, {addmsg, AddMsg}};
		{error, Reason} -> 
			io:format("Parseerror happended during message parsing: ~w!~n",[Reason])
	end,
	construct_and_parse_messages(Sock, Part, RTMsgHndlr, <<>>, Rest);
construct_and_parse_messages(Sock, Part, RTMsgHndlr, OldDataBin, <<Incomplete/binary>>) ->
	NewData = list_to_binary([OldDataBin, Incomplete]),
	construct_and_parse_messages(Sock, Part, RTMsgHndlr, NewData, <<>>).

handle_irq(passivelist) ->
	participant_manager:send_passive_partlist(self());
handle_irq(activelist) ->
	participant_manager:send_active_partlist(self());
handle_irq(_) ->
	ok.
