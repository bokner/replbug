defmodule Replbug.Server do
  @behaviour GenServer

  require Logger
  @trace_collector :trace_collector
  @local_completion_ts :local_completion_ts

  # Callbacks
  @impl true
  @spec init([:receive | :send | binary | [:receive | :send | binary | {atom, any}], ...]) ::
          {:ok, %{traces: %{}}} | {:stop, {atom | integer, any}}
  def init([trace_pattern, opts] = _args) do
    Process.flag(:trap_exit, true)
    add_redbug_instance(trace_pattern, opts)
  end

  def start(call_pattern, opts) do
    GenServer.start(__MODULE__, [call_pattern, opts], name: get_collector_name(opts[:target]))
  end

  def stop(node) do
    :redbug.stop(node)
    collector_pid = get_collector_pid(node)

    collector_pid &&
      GenServer.call(collector_pid, :get_trace_data)
  end

  defp get_collector_pid(node) do
    node
    |> get_collector_name()
    |> Process.whereis()
  end

  defp get_collector_name(nil) do
    get_collector_name(Node.self())
  end

  defp get_collector_name(node) do
    :erlang.binary_to_atom("#{@trace_collector}_#{node}")
  end

  defp add_redbug_instance(trace_pattern, opts) do
    # Get preconfigured print_fun (either default one, or specified by the caller)
    preconfigured_print_fun =
      Keyword.get(
        opts,
        :print_fun,
        if Keyword.get(opts, :silent, false) do
          fn _x -> :ok end
        else
          fn t -> default_print(t, opts) end
        end
      )

    trace_target = Keyword.get(opts, :target, Node.self())

    print_fun = fn trace_record ->
      ## Call preconfigured print_fun, if any
      preconfigured_print_fun && preconfigured_print_fun.(trace_record)
      collector_pid = get_collector_pid(trace_target)
      collector_pid && send(collector_pid, parse_trace(trace_record))
    end

    case start_redbug(trace_pattern, Keyword.put(opts, :print_fun, print_fun)) do
      {:ok, process_name} ->
        :erlang.monitor(:process, Process.whereis(process_name))
        ## 'traces' is a map of {process_pid, call_traces},
        {:ok, %{traces: Map.new(), target: trace_target, lag: lag(trace_target)}}

      error ->
        {:stop, error}
    end
  end

  defp default_print(trace_record, opts) do
    unless :erlang.element(1, trace_record) in [:meta] do
      Rexbug.Printing.print_with_opts(trace_record, opts)
    end
  end

  defp parse_trace({:meta, :stop, :dummy, {0, 0, 0, 0}}) do
    :redbug_stopping
  end

  defp parse_trace(trace_record) do
    {:trace,
     trace_record
     |> Rexbug.Printing.from_erl()
     |> extract_trace_data()}
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

  defp extract_trace_data(%Rexbug.Printing.Send{} = send_msg) do
    %{
      trace_kind: :send,
      msg: send_msg.msg,
      sender_pid: send_msg.from_pid,
      sender_mfa: send_msg.from_mfa,
      receiver_pid: send_msg.to_pid,
      timestamp: to_time(send_msg.time)
    }
  end

  defp extract_trace_data(%Rexbug.Printing.Receive{} = receive_msg) do
    %{
      trace_kind: :receive,
      msg: receive_msg.msg,
      receiver_pid: receive_msg.to_pid,
      receiver_mfa: receive_msg.to_mfa,
      timestamp: to_time(receive_msg.time)
    }
  end

  defp extract_trace_data(_unsupported_msg) do
    %{trace_kind: :unsupported}
  end

  defp to_time(%Rexbug.Printing.Timestamp{hours: h, minutes: m, seconds: s, us: us}) do
    Time.new!(h, m, s, us)
  end

  @impl true
  @spec handle_call(any, any, any) ::
          {:reply, {:unknown_message, any}, any}
          | {:stop, :normal, map, %{:traces => %{}, optional(any) => any}}
  def handle_call(:get_trace_data, _from, state) do
    {:stop, :normal, calls_by_pid(maybe_update_completion_ts(state)),
     Map.put(state, :traces, Map.new())}
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
  def handle_info(:redbug_stopping, state) do
    Logger.warning("redbug on #{state.target} is stopping...")
    {:noreply, state}
  end

  def handle_info({:trace, trace_msg}, state) do
    {:noreply, store_trace_message(trace_msg, state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{target: target_node} = state) do
    local_completion_ts = Time.utc_now()
    Logger.warning("The tracing on #{target_node} has been completed.")

    if no_traces(state) do
      Logger.warning("No traces were collected.")
      {:stop, :normal, state}
    else
      nodename =
        if target_node == Node.self() do
          ""
        else
          ":\"#{target_node}\""
        end

      Logger.warning('''
      Use:
        Replbug.stop(#{nodename}) to get the trace records into your shell.
      ''')

      {:noreply, Map.put(state, @local_completion_ts, local_completion_ts)}
    end
  end

  defp start_redbug(trace_pattern, opts) do
    {:ok, options} = Rexbug.Translator.translate_options(opts)
    {:ok, translated_pattern} = Rexbug.Translator.translate(trace_pattern)

    case :redbug.start(translated_pattern, redbug_options(options)) do
      {process_name, proc_count, func_count}
      when is_integer(proc_count) and is_integer(func_count) ->
        {:ok, process_name}

      error ->
        error
    end
  end

  defp redbug_options(options) do
    Keyword.drop(options, [:silent])
  end

  defp calls_by_pid(%{traces: traces, target: target_node} = state) do
    Map.new(
      for {pid, {finished_calls, unfinished_calls}} <- traces do
        case length(unfinished_calls) do
          unfinished_count when unfinished_count > 0 ->
            Logger.warning("""
            There #{(unfinished_count == 1 && "is") || "are"} #{unfinished_count} unfinished call(s) in the trace for #{target_node}.
            Some traced calls may still be in progress, and/or the number of trace messages has exceeded the value for :msgs option.
            """)

          _ ->
            :ok
        end

        {pid,
         %{
           finished_calls: finished_calls,
           unfinished_calls: set_call_durations(unfinished_calls, state)
         }}
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

  defp no_traces(state) do
    map_size(Map.get(state, :traces)) == 0
  end

  ## Measures (approximate) time lag between local and remote node
  def lag(node) do
    # node == Node.self() && 0 ||
    start_time = :erlang.system_time(:microsecond)
    node_time = :erpc.call(node, :erlang, :system_time, [:microsecond])
    end_time = :erlang.system_time(:microsecond)
    end_time - node_time - div(end_time - start_time, 2)
  end

  defp maybe_update_completion_ts(state) do
    (Map.has_key?(state, @local_completion_ts) && state) ||
      Map.put(state, @local_completion_ts, Time.utc_now())
  end

  defp set_call_durations([], _state) do
    []
  end

  defp set_call_durations(calls, %{local_completion_ts: local_completion_ts, lag: lag} = _state) do
    node_trace_completion_ts = Time.add(local_completion_ts, -lag, :microsecond)
    Enum.map(calls, fn call -> unfinished_call_duration(call, node_trace_completion_ts) end)
  end

  defp unfinished_call_duration(call, trace_completion_ts) do
    call
    |> Map.put(:trace_completion_ts, trace_completion_ts)
    |> Map.put(
      :estimated_duration,
      max(0, Time.diff(trace_completion_ts, call.call_timestamp, :microsecond))
    )
  end
end
