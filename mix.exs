defmodule Hook.MixProject do
  use Mix.Project

  def aliases do
    [
      check: ["format", "test", "credo --strict", "dialyzer"]
    ]
  end

  def project do
    [
      aliases: aliases(),
      app: :hook,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: [main: "Hook", extras: ["docs/examples.md"]],
      elixir: "~> 1.9",
      package: package(),
      preferred_cli_env: [check: :test],
      start_permanent: Mix.env() == :prod,
      version: "0.5.1"
    ]
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
      {:credo, ">= 0.0.0", allow_pre: true, optional: true},
      {:dialyxir, ">= 0.0.0", runtime: false, optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:mix_test_watch, ">= 0.0.0", runtime: false, optional: true}
    ]
  end

  defp description do
    "A runtime resolution library. Useful for dependency injection and mocks."
  end

  defp dialyzer do
    [plt_add_apps: [:mix]]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/verypossible/hook"}
    ]
  end
end
