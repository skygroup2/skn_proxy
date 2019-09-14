defmodule Skn.Proxy.Sup do
  use Supervisor
  @name :proxy_sup

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: @name)
  end

  def init([]) do
    children = [
    ]

    supervise(children, strategy: :one_for_one)
  end

  def start_proxy_super() do
    opts = [
      id: Luminati.Super,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [Luminati.Super]
    ]

    account = Skn.Config.get(:lum_proxy_account)
    {:ok, _} = Supervisor.start_child(@name, worker(Luminati.Super, [account], opts))
  end

  def start_proxy_static() do
    opts = [
      id: Luminati.Static,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [Luminati.Static]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(Luminati.Static, [], opts))
  end

  def start_proxy_s5(handle) do
    opts = [
      id: S5Proxy,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [S5Proxy]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(S5Proxy, [handle], opts))
  end

  def start_proxy_other() do
    opts = [
      id: ProxyOther,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [ProxyOther]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(ProxyOther, [], opts))
  end

  def start_proxy_hook() do
    http_port = Skn.Config.get(:web_proxy_port, nil)
    if is_integer(http_port) and http_port > 1024 and http_port < 65535 do
      dispatch = :cowboy_router.compile([{:_, [{:_, Skn.Proxy.RestApi, []}]}])
      :cowboy.start_clear(:http, [{:port, http_port}], %{env: %{dispatch: dispatch}})
    else
      {:ok, :ignore}
    end
  end
end