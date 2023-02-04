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

  require Logger

  @spec start(:receive | :send | binary | maybe_improper_list, keyword) ::
          :ignore | {:error, any} | {:ok, pid}
  def start(trace_pattern, opts \\ []) do
    trace_pattern
    |> pattern_to_redbug()
    # |> add_return_opt()
    |> create_call_collector(opts)
  end

  @spec stop :: %{pid() => list(any())}
  @doc """
    Stop the collection and get the traces as a map of pid => trace_records
  """
  def stop() do
    stop(Node.self())
  end

  def stop(node) do
    CollectorServer.stop(node)
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
  def replay(%{function: f, module: m, args: a, caller_pid: pid} = _call_record, timeout \\ 5_000) do
    caller_node = node(pid)

    if caller_node == Node.self() do
      apply(m, f, a)
    else
      :erpc.call(caller_node, m, f, a, timeout)
    end
  end

  defp create_call_collector(call_pattern, opts) do
    CollectorServer.start(call_pattern, opts)
  end

  ## Tracing for messages
  defp pattern_to_redbug(trace_pattern) when trace_pattern in [:send, :receive] do
    trace_pattern
  end

  defp pattern_to_redbug({m, f, a}) do
    "#{m}.#{f}/#{a}"
    |> String.replace("Elixir.", "")
    |> pattern_to_redbug()
  end

  defp pattern_to_redbug(function) when is_function(function) do
    function
    |> Function.info()
    |> then(fn info ->
      (info[:type] == :external && pattern_to_redbug({info[:module], info[:name], info[:arity]})) ||
        throw({:error, :local_functions_not_supported})
    end)
  end

  defp pattern_to_redbug(module) when is_atom(module) do
    "#{module}"
    |> String.replace("Elixir.", "")
    |> pattern_to_redbug()
  end

  ## Tracing for fun calls
  defp pattern_to_redbug(trace_pattern) when is_binary(trace_pattern) do
    ## Force `return` option
    case String.split(trace_pattern, ~r{::}, trim: true, include_captures: true) do
      [no_opts_call] ->
        "#{no_opts_call} :: return"

      [call, "::", opts] ->
        (String.contains?(opts, "return") && trace_pattern) ||
          "#{call} :: return,#{String.trim(opts)}"
    end
  end

  defp pattern_to_redbug(call_pattern_list) when is_list(call_pattern_list) do
    Enum.map(call_pattern_list, fn pattern -> pattern_to_redbug(pattern) end)
  end
end
