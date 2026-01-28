defmodule ZigCSV.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jeffhuen/zigcsv"

  def project do
    [
      app: :zig_csv,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex
      description: description(),
      package: package(),

      # Docs
      name: "ZigCSV",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    Ultra-fast CSV parsing for Elixir. A purpose-built Zig NIF with six parsing
    strategies, SIMD acceleration, and bounded-memory streaming. Drop-in NimbleCSV replacement.
    """
  end

  defp package do
    [
      name: "zig_csv",
      maintainers: ["Jeff Huen"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(
        lib
        .formatter.exs
        mix.exs
        README.md
        LICENSE
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "ZigCSV",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      extras: [
        "README.md": [title: "Overview"],
        "docs/ARCHITECTURE.md": [title: "Architecture"],
        "docs/BENCHMARK.md": [title: "Benchmarks"],
        "docs/BUILD.md": [title: "Build & Deployment"],
        "docs/COMPLIANCE.md": [title: "Compliance & Validation"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_modules: [
        Core: [
          ZigCSV,
          ZigCSV.RFC4180,
          ZigCSV.Spreadsheet
        ],
        Streaming: [
          ZigCSV.Streaming
        ],
        "Low-Level": [
          ZigCSV.Native
        ]
      ],
      groups_for_docs: [
        Parsing: &(&1[:section] == :parsing),
        Dumping: &(&1[:section] == :dumping),
        Configuration: &(&1[:section] == :config)
      ]
    ]
  end

  defp deps do
    [
      {:zigler, "~> 0.15", runtime: false},
      {:nimble_csv, "~> 1.2", only: [:dev, :test]},
      {:benchee, "~> 1.0", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
