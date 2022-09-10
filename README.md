# Replbug

**Utilities on top of [Rexbug](https://github.com/nietaki/rexbug) to facilitate REPL-style debugging in IEx shell.**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `replbug` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:replbug, "~> 0.1.0"}
  ]
end
```

## Motivation

The Erlang Trace BIFs allow to trace Erlang code on live systems.

[Rexbug](https://github.com/nietaki/rexbug) provides the interface that allows to display and/or write to external files the trace messages emitted by Erlang VM. In many cases, this would be sufficient for the purposes of debugging the code. However, if the size and/or number of tracing messages is large, it becomes more difficult to make sense of what's going on.

To illustrate the issue, let's add Rexbug dependency to our Phoenix server project:
```elixir
defp deps do
    [
      ### Our deps...
      {:replbug, "~> 0.1.0"}
    ]
  end
```

, then start a Phoenix server with the LiveDashboard enabled and look at the trace produced by `Phoenix.LiveView.Plug.call/2`

```elixir
# Start the tracing for Phoenix.LiveView.Plug.call/2
Rexbug.start("Phoenix.LiveView.Plug.call/2 :: return", time: 60_000, msgs: 1_000)
```
Then hit http://localhost:4000/dashboard or whatever link your LiveDashboard is configured for. 

We'll see a lot of output in your IEx shell, which is pretty hard to discern due to the size and truncation caused by pretty-printing.

Replbug does what Rexbug does, but additionally, we could pull the traces to IEx and materialize it as a variable that we could inspect and experiment on:

```elixir
# Make sure to close Rexbug session
Rexbug.stop
# Start the tracing for Phoenix.LiveView.Plug.call/2 with Replbug
iex(17)> Replbug.start("Phoenix.LiveView.Plug.call/2 :: return", time: 60_000, msgs: 1_000)
```

Hit http://localhost:4000/dashboard again.

The same amount of output, as with using Rexbug, but now we can get the traces into Iex and inspect them programmatically:

```elixir
iex(18)> traces = Replbug.stop
## `traces` is a map PID -> calls
iex(17)> Map.keys(traces)
[#PID<0.544.0>, #PID<0.548.0>]
## These are the processes that made the calls
## Get the list of calls across all processes
iex(19)> calls = Replbug.calls(traces)
## What calls were traced?
iex(19)> Map.keys(calls)              
[{Phoenix.LiveView.Plug, :call, 2}]
## yeah, that's the one we traced...
## Get the call records (args, returns etc.)
iex(21)> call_data = Map.get(calls, {Phoenix.LiveView.Plug, :call, 2})
## What are the arguments of the first call?
iex(22)> [arg1, arg2] =  hd(call_data).args
## We expect arg1 to be a Plug.Conn struct...
iex(23)> iex(24)> is_struct(arg1, Plug.Conn)
true
## ...and we are interested in user-agent value...
iex(24)> List.keyfind(arg1.req_headers, "user-agent", 0) 
{"user-agent",
 "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36"}
## What are durations of the calls?
iex(25)> durations = Enum.map(calls, & &1.duration)
[9411, 13954]
## Let's look at the return of the first call.
iex(26) > return = call_data.return
## We expect it to be a Plug.Conn struct as well...
iex(27) > is_struct(return, Plug.Conn)
true
## Finally, check the HTTP status
iex(28) > return.status
302

'''





