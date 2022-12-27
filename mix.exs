defmodule Replbug.MixProject do
  use Mix.Project

  def project do
    [
      app: :replbug,
      version: "0.1.5",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  defp docs do
    [
      main: "readme",
      formatter_opts: [gfm: true],
      extras: [
        "README.md"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Boris Okner <boris.okner@gmail.com>"],
      links: %{
        "GitHub" => "https://github.com/bokner/replbug"
      },
      description: description()
    ]
  end

  defp description() do
    """
    Replbug is an addition to Rexbug that allows to inspect Erlang VM traces as variables in IEx
    """
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:rexbug, git: "git@github.com:bokner/rexbug.git"},
      {:redbug, git: "git@github.com:bokner/redbug.git", override: true},
      #{:redbug, path: "/Users/bokner/projects/redbug_dev", override: true},
      #{:rexbug, path: "/Users/bokner/projects/rexbug_dev"},
      {:erlang_term, "~> 2.0"}
    ]
  end
end
