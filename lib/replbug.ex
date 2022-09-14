defmodule Replbug do
  @moduledoc """
  Utility for pulling the function call traces into your IEx shell for further analysis and experimentation.
  The code is built on top of Rexbug (https://github.com/nietaki/rexbug).
  Motivation: Rexbug provides a convenient way of tracing function calls
  by printing the trace messages to IEx shell and/or the external file.
  In addition, Replbug allows to materialize traces as a variable, and then analyze the call data
  in IEx for debugging, experimentation, collecting stats etc.
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

  @spec stop :: %{pid() => list(any())}
  @doc """
    Stop the collection and get the traces as a map of pid => trace_records
  """
  def stop do
    Rexbug.stop()

    Process.whereis(@trace_collector) &&
      GenServer.call(@trace_collector, :get_trace_data)
  end

  ## Get PIDs of all processes that made calls traced by Rexbug.
  def get_caller_pids(trace) do
    Map.keys(trace)
  end

  @spec calls(traces :: %{pid() => list(any())}) :: %{mfa() => list(any())}
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
