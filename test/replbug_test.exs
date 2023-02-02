defmodule ReplbugTest do
  use ExUnit.Case, async: false

  alias Replbug.TestUtils

  setup do
    on_exit(fn -> Replbug.stop() end)
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

    {:ok, _collector_pid} =
      Replbug.start(["DateTime.utc_now/0", :send, :receive],
        procs: [my_pid],
        time: timeout,
        msgs: 10000
      )

    send(my_pid, :test_msg)
    _returns = Enum.map(1..num_calls, fn _i -> DateTime.utc_now() end)
    :timer.sleep(2 * timeout)
    calls = Replbug.stop() |> Replbug.calls()
    assert length(Map.get(calls, {DateTime, :utc_now, 0})) == num_calls
  end

  test "Verifies call stats" do
    times = [100, 100, 500, 250, 50, 100, 300, 70, 50, 30]

    timer_tcs =
      Enum.map(times, fn time ->
        {tc, :ok} = :timer.tc(fn -> TestUtils.run_for_time(time) end)
        tc
      end)

    mfa = {Replbug.TestUtils, :run_for_time, 1}

    ## We expect the number of trace messages to be twice the number of calls
    ## (one for the function call, one for the return)
    msg_num = 2 * length(times)
    {:ok, _collector_pid} = Replbug.start(mfa, msgs: msg_num)

    Enum.each(times, &TestUtils.run_for_time/1)
    ## Give tracer a bit of time to catch remaining calls
    :timer.sleep(50)
    traces = Replbug.stop()
    calls = Replbug.calls(traces)
    durations = calls |> Map.get(mfa) |> Enum.map(& &1.duration)
    total_count = Replbug.Utils.counts(calls) |> Map.get(mfa)
    total_duration = Replbug.Utils.total_durations(calls) |> Map.get(mfa)

    assert length(durations) == length(times)
    assert total_count == length(times)
    assert Enum.sum(durations) == total_duration

    # See if the durations reported by tracer are close enough to :timer.tc stats
    # While the number for individual calls could be different, the totals should be very close.
    # Arbitrary value for the difference is 100 microseconds times the number of calls.
    # This might still fail occasionally, in which case you should look at how much those numbers are off
    # and decide if you should have doubts about either :timer.tc or the tracer :-)
    diff_threshold = 100 * length(times)
    assert abs(Enum.sum(timer_tcs) - Enum.sum(durations)) <= diff_threshold
  end

  test "Replbug registers and uses a rexbug process with 'rexbug_<node>' name" do
    Replbug.start(":erlang.system_time/0")
    :timer.sleep(50)
    ## Trigger the trace
    :erlang.system_time()
    assert :erlang.whereis(:redbug) == :undefined
    assert is_pid(:erlang.whereis(:redbug.redbug_name(Node.self())))
    :timer.sleep(50)
    traces = Replbug.stop()
    :timer.sleep(50)
    assert :erlang.whereis(:redbug.redbug_name(Node.self())) == :undefined
    assert map_size(traces) == 1
    assert hd(Map.keys(Replbug.calls(traces))) == {:erlang, :system_time, 0}
  end
end

defmodule Replbug.TestUtils do
  def run_for_time(time) do
    :timer.sleep(time)
  end
end
