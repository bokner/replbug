defmodule Replbug do
  @moduledoc """
  Utility for pulling the function call traces into your IEx shell for further analysis and experimentation.
  The code is built on top of Rexbug (https://github.com/nietaki/rexbug).
  Motivation: Rexbug provides a convenient way of tracing function calls
  by printing the trace messages to IEx shell and/or the external file.
  In addition, Replbug allows to materialize traces as a variable, and then analyze the call data
  in IEx for debugging, experimentation, collecting stats etc.
  Example 1:
   Trace DateTime.utc_now/0. Let the tracer run for 60 secs or until 10 trace messages are emitted.
    iex(1)> Replbug.start("DateTime.utc_now/0", time: 60_000, msgs: 10)
    You could either wait for the system to make DateTime.utc_now/0 calls, or call it manually in IEx.
    At any time, stop collecting traces and get the call trace records:
    iex(3)> call_traces = Replbug.stop
    %{
    #PID<0.1392.0> => [
      %{
        args: [],
        call_timestamp: ~T[13:58:20.183042],
        caller_pid: #PID<0.1392.0>,
        function: :utc_now,
        module: DateTime,
        parent: Verk.ScheduleManager,
        return: ~U[2022-04-11 17:58:20.183039Z],
        return_timestamp: ~T[13:58:20.183054]
      },
      %{
        args: [],
        call_timestamp: ~T[13:58:20.184928],
        caller_pid: #PID<0.1392.0>,
        function: :utc_now,
        module: DateTime,
        parent: Verk.ScheduleManager,
        return: ~U[2022-04-11 17:58:20.184925Z],
        return_timestamp: ~T[13:58:20.184937]
      }
    ],
    #PID<0.1498.0> => [
      %{
        args: [],
        call_timestamp: ~T[13:58:18.183879],
        caller_pid: #PID<0.1498.0>,
        function: :utc_now,
        module: DateTime,
        parent: %Rexbug.Printing.MFA{a: 1, f: :init, m: Oban.Plugins.Stager},
        return: ~U[2022-04-11 17:58:18.183883Z],
        return_timestamp: ~T[13:58:18.183899]
      },
      %{
        args: [],
        call_timestamp: ~T[13:58:19.197818],
        caller_pid: #PID<0.1498.0>,
        function: :utc_now,
        module: DateTime,
        parent: %Rexbug.Printing.MFA{a: 1, f: :init, m: Oban.Plugins.Stager},
        return: ~U[2022-04-11 17:58:19.197821Z],
        return_timestamp: ~T[13:58:19.197836]
      }
    ],
    #PID<0.1538.0> => [
      %{
        args: [],
        call_timestamp: ~T[13:58:17.925199],
        caller_pid: #PID<0.1538.0>,
        function: :utc_now,
        module: DateTime,
        parent: %Rexbug.Printing.MFA{a: 1, f: :init, m: Oban.Queue.Producer},
        return: ~U[2022-04-11 17:58:17.925201Z],
        return_timestamp: ~T[13:58:17.925216]
      }
    ]
  }
  This tells us that calls to DateTime.utc_now/0 were made by 3 processes:
  <0.1392.0> (Verk.ScheduleManager, 2 times), <0.1498.0> (Oban.Plugins.Stager, 2 times) and
  <0.1538.0> (Oban.Queue.Producer, once)
  Example 2: (get the call durations for the given MFA):
  iex(1)> Replbug.start("DateTime", "String.contains?/2"], time: 60_000, msgs: 100)
  ### ...do some function calls with DateTime and/or String.contains?
  iex(2)> Enum.each(1..4, fn _ -> DateTime.utc_now() end)
  .......
  iex(3)> String.contains?("aaa", "b")
  ### retrieve the call traces
  iex(4)> calls = Replbug.stop |> Replbug.calls()
  ### Get the list of calls:
  iex(5)> Map.keys(calls)
  [
  {DateTime, :__info__, 1},
  {DateTime, :convert, 2},
  {DateTime, :from_unix, 3},
  {DateTime, :from_unix!, 3},
  {DateTime, :utc_now, 0},
  {DateTime, :utc_now, 1},
  {String, :contains?, 2}
  ]
  ### Get the call durations for DataTime.utc_now/0 :
  iex(6)> calls |> Map.get({DateTime, :utc_now, 0}) |> Enum.map(& &1.duration)
  [35, 14, 12, 12]
  ### Replay calls for DateTime.utc_now/0 (use replay/1 with caution in prod!):
  iex(7)> calls |> Map.get({DateTime, :utc_now, 0}) |> Enum.map(&Replbug.replay/1)
  [~U[2022-08-31 21:02:02.397846Z], ~U[2022-08-31 21:02:02.397857Z],
   ~U[2022-08-31 21:02:02.397859Z], ~U[2022-08-31 21:02:02.397860Z]]
  """

  alias Replbug.Server, as: CollectorServer

  @trace_collector :trace_collector

  @spec start(:receive | :send | binary | maybe_improper_list, keyword) ::
          :ignore | {:error, any} | {:ok, pid}
  def start(call_pattern, opts \\ []) do
    # Get preconfigured print_fun (either default one, or specified by the caller)
    preconfigured_print_fun =
      Keyword.get(opts, :print_fun, fn t -> Rexbug.Printing.print_with_opts(t, opts) end)

    print_fun = fn trace_record ->
      ## Call preconfigured print_fun, if any
      preconfigured_print_fun && preconfigured_print_fun.(trace_record)
      pid = Process.whereis(@trace_collector)
      pid && send(pid, {:trace, parse_trace(trace_record)})
    end

    call_pattern
    |> add_return_opt()
    |> create_call_collector(Keyword.put(opts, :print_fun, print_fun))
  end

  @spec stop :: any
  def stop do
    Rexbug.stop()

    Process.whereis(@trace_collector) &&
      GenServer.call(@trace_collector, :get_trace_data)
  end

  ## Get PIDs of all processes that made calls traced by Rexbug.
  def get_caller_pids(trace) do
    Map.keys(trace)
  end

  @spec calls(map) :: map
  @doc """
  Group the trace by function calls (MFA).
  """

  def calls(trace) do
    trace
    |> Map.values()
    |> List.flatten()
    |> Enum.group_by(fn trace_rec ->
      {trace_rec.module, trace_rec.function, length(trace_rec.args)}
    end)
  end

  @doc """
  Repeat the call with the same arguments, for instance, after you've applied the changes to the code and reloaded the module.
  Use replay/1 with caution in prod!
  Also, it may not work as expected due to changes happened in between the initial call and the time of replay.
  """
  @spec replay(%{:args => list, :function => atom, :module => atom | tuple, optional(any) => any}) ::
          any
  def replay(%{function: f, module: m, args: a} = _call_record) do
    apply(m, f, a)
  end

  defp create_call_collector(call_pattern, rexbug_opts) do
    GenServer.start(CollectorServer, [call_pattern, rexbug_opts], name: @trace_collector)
  end

  defp add_return_opt(trace_pattern) when trace_pattern in [:send, :receive] do
    # throw({:error, :tracing_messages_not_supported})
    trace_pattern
  end

  defp add_return_opt(call_pattern) when is_binary(call_pattern) do
    ## Force `return` option
    case String.split(call_pattern, ~r{::}, trim: true, include_captures: true) do
      [no_opts_call] ->
        "#{no_opts_call} :: return"

      [call, "::", opts] ->
        (String.contains?(opts, "return") && call_pattern) ||
          "#{call} :: return,#{String.trim(opts)}"
    end
  end

  defp add_return_opt(call_pattern_list) when is_list(call_pattern_list) do
    Enum.map(call_pattern_list, fn pattern -> add_return_opt(pattern) end)
  end

  defp parse_trace(trace_record) do
    trace_record
    |> Rexbug.Printing.from_erl()
    |> extract_trace_data()
  end

  defp extract_trace_data(
         %Rexbug.Printing.Call{
           mfa: mfa,
           from_pid: caller_pid,
           from_mfa: parent,
           time: rexbug_time
         } = trace_rec
       ) do
    %{
      trace_kind: :call,
      module: mfa.m,
      function: mfa.f,
      args: mfa.a,
      parent: parent,
      caller_pid: caller_pid,
      call_timestamp: to_time(rexbug_time),
      stack: trace_rec.dump && Rexbug.Printing.extract_stack(trace_rec.dump)
    }
  end

  defp extract_trace_data(%Rexbug.Printing.Return{
         mfa: mfa,
         return_value: return_value,
         from_pid: caller_pid,
         time: rexbug_time
       }) do
    %{
      trace_kind: :return,
      module: mfa.m,
      function: mfa.f,
      arity: mfa.a,
      return: return_value,
      caller_pid: caller_pid,
      return_timestamp: to_time(rexbug_time)
    }
  end

  defp extract_trace_data(%Rexbug.Printing.Send{}) do
  end

  defp extract_trace_data(%Rexbug.Printing.Receive{}) do
    %{trace_kind: :receive}
  end

  defp to_time(%Rexbug.Printing.Timestamp{hours: h, minutes: m, seconds: s, us: us}) do
    Time.new!(h, m, s, us)
  end
end

defmodule Replbug.Server do
  @behaviour GenServer

  require Logger
  # Callbacks
  @impl true
  @spec init([:receive | :send | binary | [:receive | :send | binary | {atom, any}], ...]) ::
          {:ok, %{traces: %{}}} | {:stop, {atom | integer, any}}
  def init([call_pattern, rexbug_opts] = _args) do
    Process.flag(:trap_exit, true)

    case start_rexbug(call_pattern, rexbug_opts) do
      :ok ->
        :erlang.monitor(:process, Process.whereis(:redbug))
        ## The state is a map of {process_pid, call_traces},
        {:ok, %{traces: Map.new()}}

      error ->
        {:stop, error}
    end
  end

  @impl true
  @spec handle_call(any, any, any) ::
          {:reply, {:unknown_message, any}, any}
          | {:stop, :normal, map, %{:traces => %{}, optional(any) => any}}
  def handle_call(:get_trace_data, _from, state) do
    {:stop, :normal, calls_by_pid(state.traces), Map.put(state, :traces, Map.new())}
  end

  def handle_call(unknown_message, _from, state) do
    {:reply, {:unknown_message, unknown_message}, state}
  end

  @impl true
  @spec handle_cast(any, any) :: {:noreply, any}
  def handle_cast(_cast_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:trace, trace_msg}, state) do
    {:noreply, store_trace_message(trace_msg, state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warn('''
    The tracing has been completed. Use:
      Replbug.stop to get the trace records into your shell.
    ''')

    {:noreply, state}
  end

  defp start_rexbug(call_pattern, opts) do
    case Rexbug.start(call_pattern, opts) do
      {proc_count, func_count} when is_integer(proc_count) and is_integer(func_count) ->
        :ok

      error ->
        error
    end
  end

  defp calls_by_pid(traces) do
    Map.new(
      for {pid, {finished_calls, unfinished_calls}} <- traces do
        case length(unfinished_calls) do
          unfinished_count when unfinished_count > 0 ->
            Logger.warn("""
            There are #{unfinished_count} unfinished calls in the trace.
            Some traced calls may still be in progress, and/or the number of trace messages has exceeded the value for :msgs option.
            """)

          _ ->
            :ok
        end

        {pid, Enum.reverse(finished_calls)}
      end
    )
  end

  defp store_trace_message(
         %{trace_kind: :call, caller_pid: caller_pid} = call_trace_msg,
         %{traces: traces} = state
       ) do
    Map.put(
      state,
      :traces,
      Map.update(traces, caller_pid, {[], [call_trace_msg]}, fn {finished_calls, unfinished_calls} ->
        {finished_calls, [call_trace_msg | unfinished_calls]}
      end)
    )
  end

  defp store_trace_message(
         %{trace_kind: :return, caller_pid: caller_pid} = return_trace_msg,
         %{traces: traces} = state
       ) do
    Map.put(
      state,
      :traces,
      Map.update(traces, caller_pid, {}, fn {finished_calls, [last_call | rest]} ->
        {
          [
            return_trace_msg
            |> Map.merge(last_call)
            |> Map.drop([:arity, :trace_kind])
            |> Map.put(:duration, call_duration(return_trace_msg, last_call))
            | finished_calls
          ],
          rest
        }
      end)
    )
  end

  ## We curently do not store message traces.
  ## TODO: handle message traces
  defp store_trace_message(_send_receive_msg, state) do
    state
  end

  defp call_duration(return_rec, call_rec) do
    Time.diff(return_rec.return_timestamp, call_rec.call_timestamp, :microsecond)
  end
end
