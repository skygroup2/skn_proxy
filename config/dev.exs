use Mix.Config

config :skn_proxy,
  namespace: Skn,
  ecto_repos: [Skn.Proxy.Repo]

config :skn_proxy,
  Skn.Proxy.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "freevpn",
  password: "freevpn@#*",
  database: "freevpn",
  hostname: "127.0.0.1",
  pool_size: 2,
  loggers: []
