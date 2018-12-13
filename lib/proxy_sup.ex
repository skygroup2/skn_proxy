defmodule Proxy.Sup do
  use Supervisor
  @name :proxy_sup

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: @name)
  end

  def init([]) do
    children = [
      worker(Proxy.LocalKeeper, []),
      worker(Proxy.LocalKeeperAck, [])
    ]

    supervise(children, strategy: :one_for_one)
  end

  def start_proxy_keeper do
    master = Skn.Config.get(:master, nil)

    if master == node() do
      Enum.each(0..(Proxy.Keeper.size() - 1), fn id ->
        opts = [
          id: Proxy.Keeper.name(id),
          function: :start_link,
          restart: :transient,
          shutdown: 5000,
          modules: [Proxy.Keeper]
        ]

        Supervisor.start_child(@name, worker(Proxy.Keeper, [id], opts))
      end)
    else
      {:ok, :ignore}
    end
  end

  def start_proxy_group_super() do
    for id <- 1..ProxyGroup.groups() do
      start_proxy_group(id)
    end
    :ok
  end

  def start_proxy_group(id) do
    opts = [
      id: id,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [ProxyGroup]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(ProxyGroup, [id], opts))
  end

  def start_proxy_super() do
    opts = [
      id: Luminati.Super,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [Luminati.Super]
    ]

    account = Skn.Config.get(:proxy_account)
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

  def start_geoip() do
    opts = [
      id: GeoIP,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [GeoIP]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(GeoIP, [], opts))
  end
end