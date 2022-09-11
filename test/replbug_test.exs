defmodule ReplbugTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Replbug.stop end)
  end

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
    assert num_calls == length(call_recs)
    ## Check the call args
    assert Enum.all?(call_recs, fn rec -> rec.args == [call_arg] end)
    ## Check the call returns
    assert Enum.map(call_recs, & &1.return) == returns
    ## Replay the calls (use with caution in prod!)
    assert Enum.all?(call_recs, fn rec -> rec.return == Replbug.replay(rec) end)
  end

  test "Allows :send and :receive in trace specs" do
    timeout = 500
    num_calls = 3
    my_pid = self()
    {:ok, _collector_pid} = Replbug.start(["DateTime.utc_now/0", :send, :receive], procs: [my_pid], time: timeout, msgs: 10000)
    send my_pid, :test_msg
    _returns = Enum.map(1..num_calls, fn _i -> DateTime.utc_now end)
    :timer.sleep(2 * timeout)
    calls = Replbug.stop() |> Replbug.calls()
    assert length(Map.get(calls, {DateTime, :utc_now, 0})) == num_calls
  end

end
