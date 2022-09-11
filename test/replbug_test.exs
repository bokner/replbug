defmodule ReplbugTest do
  use ExUnit.Case

  test "Replbug functionality" do
    timeout = 500
    {:ok, _collector_pid} = Replbug.start("MapSet.new/_", time: timeout, msgs: 10)
    ## Trigger tracing
    num_calls = 4
    call_arg = [1, 2, 3, 4]
    returns = Enum.map(1..num_calls, fn _i -> MapSet.new(call_arg) end)
    ## Wait for tracing to complete on timeout
    :timer.sleep(2 * timeout)
    ## Get the call traces
    calls = Replbug.stop() |> Replbug.calls()
    assert Map.keys(calls) == [{MapSet, :new, 1}]

    call_recs = Map.get(calls, {MapSet, :new, 1})
    ## Check if all calls are in the trace
    assert num_calls = length(call_recs)
    ## Check the call args
    assert Enum.all?(call_recs, fn rec -> rec.args == [call_arg] end)
    ## Check the call returns
    assert Enum.map(call_recs, & &1.return) == returns
    ## Replay the calls (use with caution in prod!)
    assert Enum.all?(call_recs, fn rec -> rec.return == Replbug.replay(rec) end)
  end
end
