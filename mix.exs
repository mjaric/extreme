defmodule Extreme.Mixfile do
  use Mix.Project

  def project do
    [
      app: :extreme,
      version: "1.0.6",
      elixir: "~> 1.11",
      elixirc_paths: _elixirc_paths(Mix.env()),
      source_url: "https://github.com/exponentially/extreme",
      description: """
      Elixir TCP client for EventStore.
      """,
      package: _package(),
      start_permanent: Mix.env() == :prod,
      preferred_cli_env: [
        vcr: :test,
        "vcr.delete": :test,
        "vcr.check": :test,
        "vcr.show": :test
      ],
      deps: _deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets]
    ]
  end

  # Specifies which paths to compile per environment.
  defp _elixirc_paths(:test), do: ["lib", "test/support"]
  defp _elixirc_paths(_), do: ["lib"]

  defp _deps do
    [
      {:exprotobuf, "~> 1.2.9"},
      {:elixir_uuid, "~> 1.2"},
      {:telemetry, "~> 0.4 or ~> 1.0"},
      # needed when connecting to EventStore cluster (node_type: :cluster | :cluster_dns)
      {:jason, "~> 1.1", optional: true},

      # testing
      {:exvcr, "~> 0.10", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev}
      # {:earmark, "~> 1.2", only: :test},
      # {:inch_ex, "~> 1.0", only: :test},
      # {:excoveralls, "~> 0.9", only: :test},
    ]
  end

  defp _package do
    [
      files: ["lib", "mix.exs", "README*", "LICENSE*", "include"],
      maintainers: ["Milan Burmaja"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/exponentially/extreme"}
    ]
  end
end
