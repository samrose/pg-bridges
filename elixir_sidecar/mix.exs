defmodule ElixirSidecar.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_sidecar,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirSidecar.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:msgpax, "~> 2.3"},
      {:burrito, "~> 1.0"}
    ]
  end

  defp releases do
    # Determine current platform
    current_target = case :os.type() do
      {:unix, :darwin} ->
        case :erlang.system_info(:system_architecture) |> to_string() do
          "aarch64" <> _ -> [macos_arm: [os: :darwin, cpu: :aarch64]]
          _ -> [macos: [os: :darwin, cpu: :x86_64]]
        end
      {:unix, :linux} ->
        [linux: [os: :linux, cpu: :x86_64]]
      _ ->
        [linux: [os: :linux, cpu: :x86_64]]  # Default fallback
    end

    [
      elixir_sidecar: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: current_target,
          run_args: [],
          extra_steps: [
            wrap: [
              extra_args: [
                "--app-version", "0.1.0"
              ]
            ]
          ]
        ]
      ]
    ]
  end
end