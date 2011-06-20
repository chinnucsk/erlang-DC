-module(rt_message_handler).
-export([rt_message_handler/1]).

rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, {bufferlist, B}}) ->
	receive 
		{wait_for_realtime_msg, {wcn, W}, {rn, R}, {timeout, T}} ->
			io:format("[rt_message_handler][wait]: have to wait for ~w ~w~n",[W,R]),
			rt_message_handler({receive_rt, {part, P}, {con, C}, {wcn, W}, {rn, R}, {bufferlist, B}, {timeout, T}});
		{wait_for_realtime_msg, {wcn, NW}, {rn, R}, {timeout, T}} ->
			rt_message_handler({receive_rt, {part, P}, {con, C}, {wcn, NW}, {rn, R}, {bufferlist, []}, {timeout, T}});
		{add, {part, P}, {wcn, W}, {rn, R}, {addmsg, A}} ->
			io:format("rt_message_handler: not yet in receive_rt mode, buffering message: ~w~n",[A]),
				rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, 
						{bufferlist, B ++ [{add, {part, P}, {con, C}, {wcn, W}, {rn, R}, {addmsg, A}}]}});
		Error ->
			io:format("[rt_message_handler][wait]: This message is not for me: ~w ~n",[Error]),
			rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, {bufferlist, B}})
	end;

rt_message_handler({receive_rt, {part, P}, {con, C}, {wcn, W}, {rn, R}, {bufferlist, []}, {timeout, T}}) ->
	receive 
		{add, {part, P}, {wcn, W}, {rn, R}, {addmsg, A}} ->
			io:format("[rt_message_handler]: Add message received for wcn ~w round ~w~n",[W,R]),
			gen_fsm:send_event(workcycle, {add, {part, P}, {con, C}, {wcn, W}, {rn, R}, {addmsg, A}}),
			rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, {bufferlist, []}});
		{add, {part, P}, {wcn, W}, {rn, NR}, {addmsg, A}} when NR >= R ->
			io:format("rt_message_handler: officially  waiting for older messages. buffering: ~w~n",[A]),
				rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, 
						{bufferlist, [{add, {part, P}, {con, C}, {wcn, W}, {rn, R}, {addmsg, A}}]}});
		{wait_for_realtime_msg, {wcn, NW}, {rn, NR}, {timeout, T}} ->
			io:format("[rt_message_handler][rt]: now waiting for wcn ~w, rn ~w~n", [NW, NR]),
			rt_message_handler({receive_rt, {part, P}, {con, C}, {wcn, NW}, {rn, NR}, {bufferlist, []}, {timeout, T}});
		Error ->
			io:format("This message is not for me [rt]: ~w ~n (waiting for wcn ~w and rn ~w)~n",[Error, W, R]),
			rt_message_handler({receive_rt, {part, P}, {con, C}, {wcn, W}, {rn, R}, {bufferlist, []}, {timeout, T}})
		after T ->
			gen_fsm:send_event(workcycle, {addtimeout, {part, P}, {con, C}, {wcn, W}, {rn, R}}),
			rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, {bufferlist, []}})
	end;

rt_message_handler({receive_rt, {part, P}, {con, C},{wcn, W}, {rn, _RN}, {bufferlist, [H|T]}, {timeout, _To}}) ->
	io:format("[rt_handler] sending buffered message ~n"),
	gen_fsm:send_event(workcycle, H),
	rt_message_handler({wait, {part, P}, {con, C}, {wcn, W}, {bufferlist, T}});

rt_message_handler(E) ->
	io:format("sorry, what? ~w~n", [E]).
