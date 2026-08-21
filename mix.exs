defmodule AshOwnership.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_ownership,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() not in [:dev, :test],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Ownership semantics for Ash relationships and lifecycle locks.",
      package: package(),
      source_url: "https://github.com/devall-org/ash_ownership",
      homepage_url: "https://github.com/devall-org/ash_ownership",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, ">= 0.0.0"},
      {:spark, ">= 0.0.0"},
      {:ash_archival, ">= 0.0.0", only: :test},
      {:ash_postgres, ">= 0.0.0", only: :test},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "ash_ownership",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/devall-org/ash_ownership"
      }
    ]
  end
end
