defmodule ReplbugTest do
  use ExUnit.Case
  doctest Replbug

  test "greets the world" do
    assert Replbug.hello() == :world
  end
end
