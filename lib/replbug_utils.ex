defmodule Replbug.Utils do
  def mfas(calls) do
    Map.keys(calls)
  end

  def call_stats(calls, stats_fun) when is_map(calls) do
    Map.new(calls, fn {mfa, mfa_calls} ->
      {mfa, stats_fun.(mfa_calls)}
    end)
  end

  def counts(calls) when is_map(calls) do
    call_stats(calls, &length/1)
  end

  def total_durations(calls) when is_map(calls) do
    call_stats(calls, &total_duration/1)
  end

  def max_duration_calls(calls) when is_map(calls) do
    call_stats(calls, &max_duration_call/1)
  end

  def min_duration_calls(calls) when is_map(calls) do
    call_stats(calls, &min_duration_call/1)
  end

  def average_durations(calls) when is_map(calls) do
    call_stats(calls, &average_duration/1)
  end

  def max_args(calls) when is_map(calls) do
    call_stats(calls, fn mfa_calls ->
      Enum.max_by(
        mfa_calls,
        fn call ->
          Enum.max(arg_sizes(call))
        end
      )
    end)
  end

  def max_returns(calls) when is_map(calls) do
    call_stats(calls, fn mfa_calls ->
      Enum.max_by(mfa_calls, &return_size/1)
    end)
  end

  def summary(calls) when is_map(calls) do
    call_stats(calls, &mfa_summary/1)
  end

  defp total_duration(calls) when is_list(calls) do
    Enum.reduce(calls, 0, fn call, acc -> acc + call.duration end)
  end

  defp average_duration(calls) when is_list(calls) do
    total_duration(calls) / length(calls)
  end

  defp min_duration_call(calls) when is_list(calls) do
    Enum.min_by(calls, & &1.duration)
  end

  defp max_duration_call(calls) when is_list(calls) do
    Enum.max_by(calls, & &1.duration)
  end

  defp mfa_summary(calls) when is_list(calls) do
    {min_d, max_d, total_d} =
      Enum.reduce(calls, {:infinity, 0, 0}, fn %{duration: d} = _call,
                                               {min_acc, max_acc, total_acc} ->
        {min(d, min_acc), max(d, max_acc), d + total_acc}
      end)

    %{
      count: length(calls),
      min_duration: min_d,
      max_duration: max_d,
      total_duration: total_d,
      average_duration: total_d / length(calls)
    }
  end

  defp arg_sizes(call) do
    Enum.map(call.args, fn arg -> :erlang_term.byte_size(arg) end)
  end

  defp return_size(call) do
    :erlang_term.byte_size(call.return)
  end

  @spec collect_traces(:receive | :send | binary | maybe_improper_list, integer, keyword) :: %{
          optional(pid) => list
        }
  @doc """
        Collect the traces over the `time_interval` duration.
        Note: it's a blocking call, use with care
  """
  def collect_traces(call_pattern, time_interval, opts \\ []) do
    case Replbug.start(call_pattern, Keyword.put(opts, :time, time_interval)) do
      {:ok, _pid} ->
        Process.sleep(time_interval + 100)
        Replbug.stop()

      error ->
        error
    end
  end
end
