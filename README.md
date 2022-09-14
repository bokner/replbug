# Replbug

**Utilities on top of [Rexbug](https://github.com/nietaki/rexbug) to facilitate REPL-style debugging in IEx shell.**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `replbug` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:replbug, "~> 0.1"}
  ]
end
```

## Motivation

The Erlang Trace BIFs allow to trace Erlang code on live systems.

[Rexbug](https://github.com/nietaki/rexbug) displays and/or writes to external files in human-readable format the trace messages emitted by Erlang VM. In many cases, this would be sufficient for the purposes of debugging the code. However, if the size and/or number of tracing messages is large, it becomes more difficult to make sense of what's going on just by visually checking the tracing output.

To illustrate the issue, let's add Replbug dependency to our Phoenix server project:
```elixir
defp deps do
    [
      ### Our deps...
      {:replbug, "~> 0.1"}
    ]
  end
```

and start a Phoenix server with the LiveDashboard enabled.

Now start tracing `Phoenix.LiveView.Plug.call/2` in IEx **using Rexbug**:

```elixir
# Start the tracing for Phoenix.LiveView.Plug.call/2
iex(1)> Rexbug.start("Phoenix.LiveView.Plug.call/2 :: return", time: 60_000, msgs: 1_000)
```
Then hit http://localhost:4000/dashboard or whatever link your LiveDashboard is configured for. 

We'll see a lot of output in your IEx shell, which is pretty hard to comprehend due to it's size and truncations caused by pretty-printing etc.

## Solution 

Replbug preserves all functionality of Rexbug. Additionally, it allows to materialize trace records as variables that we could inspect and experiment with the collected traces in IEx shell. Let's **use Replbug** this time to trace the same function:

```elixir
# Make sure to close Rexbug session
iex(2)> Rexbug.stop
# Start the tracing for Phoenix.LiveView.Plug.call/2 with Replbug
iex(3)> Replbug.start("Phoenix.LiveView.Plug.call/2 :: return", time: 60_000, msgs: 1_000)
```

Hit http://localhost:4000/dashboard again.

The same amount of output, as with using Rexbug, but now we can get the traces into IEx and inspect them programmatically:

```elixir
iex(3)> traces = Replbug.stop
## `traces` is a map PID -> calls
iex(4)> Map.keys(traces)
[#PID<0.544.0>, #PID<0.548.0>]
## These are the processes that made the calls
## Get the list of calls across all processes
iex(5)> calls = Replbug.calls(traces)
## What calls were traced?
iex(6)> Map.keys(calls)              
[{Phoenix.LiveView.Plug, :call, 2}]
## yeah, that's the one we traced...
## Get the call records (args, returns etc.)
iex(7)> call_data = Map.get(calls, {Phoenix.LiveView.Plug, :call, 2})
## What are the arguments of the first call?
iex(8)> [arg1, arg2] =  hd(call_data).args
## We expect arg1 to be a Plug.Conn struct...
iex(9)> iex(24)> is_struct(arg1, Plug.Conn)
true
## ...and we are interested in user-agent value...
iex(10)> List.keyfind(arg1.req_headers, "user-agent", 0) 
{"user-agent",
 "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36"}
## What are durations of the calls?
iex(11)> durations = Enum.map(calls, & &1.duration)
[9411, 13954]
## Let's look at the return of the first call.
iex(12) > return = call_data.return
## We expect it to be a Plug.Conn struct as well...
iex(13) > is_struct(return, Plug.Conn)
true
## Finally, check the HTTP status
iex(14) > return.status
302

```

## Status

As of now, Replbug only supports tracing of function calls.
Support for tracing of inter-process messages is planned for upcoming versions.








