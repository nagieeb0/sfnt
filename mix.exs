defmodule Sfnt.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nagieeb0/sfnt"

  def project do
    [
      app: :sfnt,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Font subsetting in pure Elixir. Strips an OpenType or TrueType face " <>
          "down to the glyphs a document actually draws — 158 KB to 7 KB on a " <>
          "typical invoice — so PDFs can embed fonts without carrying them whole.",
      package: package(),
      docs: docs(),
      name: "Sfnt",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "OpenType spec" => "https://learn.microsoft.com/en-us/typography/opentype/spec/",
        "CFF spec" => "https://adobe-type-tools.github.io/font-tech-notes/pdfs/5176.CFF.pdf"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
