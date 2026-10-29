defmodule Ambush.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ambush,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ex_unit],
      mod: {Ambush.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.18"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end
end
