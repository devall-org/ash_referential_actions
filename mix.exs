defmodule AshReferentialActions.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_referential_actions,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() not in [:dev, :test],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Explicit cascade, restrict, nilify, and do-nothing semantics for Ash relationships.",
      package: package(),
      source_url: "https://github.com/devall-org/ash_referential_actions",
      homepage_url: "https://github.com/devall-org/ash_referential_actions",
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
      {:ash, "~> 3.31"},
      {:ash_archival, "~> 2.0", optional: true},
      {:ash_postgres, "~> 2.11", optional: true},
      {:spark, "~> 2.7"},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "ash_referential_actions",
      files: ["lib", ".formatter.exs", "mix.exs", "README.md", "LICENSE", "usage-rules.md"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/devall-org/ash_referential_actions"
      }
    ]
  end
end
