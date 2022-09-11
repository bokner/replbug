defmodule Replbug.MixProject do
  use Mix.Project

  def project do
    [
      app: :replbug,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
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
      {:rexbug, "~> 1.0"}
    ]
  end
end
