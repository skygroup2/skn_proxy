defmodule SknProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :skn_proxy,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [
        :logger,
        :lager,
        :jason,
        :mnesia,
        :skn_proto,
        :skn_lib,
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:skn_lib, git: "git@gitlab.com:gskynet_lib/skn_lib.git", branch: "master"},
      {:skn_proto, git: "git@gitlab.com:gskynet_lib/skn_proto.git", branch: "master"},
    ]
  end
end
