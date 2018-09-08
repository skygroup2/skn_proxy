defmodule Luminati.Sup do
  use Supervisor
  @name :luminati_sup

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: @name)
  end

  def init([]) do
    children = [
      worker(Luminati.LocalKeeper, []),
      worker(Luminati.LocalKeeperAck, [])
    ]

    supervise(children, strategy: :one_for_one)
  end

  def start_proxy_keeper do
    master = Skn.Config.get(:master, :farmer1@erlnode1)

    if master == node() do
      Enum.each(0..(Luminati.Keeper.size() - 1), fn id ->
        opts = [
          id: Luminati.Keeper.name(id),
          function: :start_link,
          restart: :transient,
          shutdown: 5000,
          modules: [Luminati.Keeper]
        ]

        Supervisor.start_child(@name, worker(Luminati.Keeper, [id], opts))
      end)
    else
      {:ok, :ignore}
    end
  end

  def start_proxy_group_super do
    for id <- 1..ProxyGroup.groups() do
      start_proxy_group(id, :super)
    end

    :ok
  end

  def start_proxy_group(id, group \\ nil) do
    opts = [
      id: id,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [ProxyGroup]
    ]

    group =
      case group do
        nil -> Enum.shuffle(Skn.DB.ProxyList.list_tag(id))
        :super -> Enum.shuffle(Skn.DB.ProxyList.list_tag(:super))
        _ -> group
      end

    {:ok, _} = Supervisor.start_child(@name, worker(ProxyGroup, [{id, group}], opts))
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

  def start_proxy_static(handle) do
    opts = [
      id: Luminati.Static,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [Luminati.Static]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(Luminati.Static, [handle], opts))
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

  def start_proxy_hulk(handle) do
    opts = [
      id: ProxyHulk,
      function: :start_link,
      restart: :transient,
      shutdown: 5000,
      modules: [ProxyHulk]
    ]

    {:ok, _} = Supervisor.start_child(@name, worker(ProxyHulk, [handle], opts))
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

defmodule Luminati.Super do
  @moduledoc """
      scan super proxy
  """
  use GenServer
  require Logger
  @name :proxy_super
  import Skn.Util,
    only: [
      reset_timer: 3
    ]

  import HackneyEx,
    only: [
      decode_gzip: 1
    ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: @name)
  end

  def init({user, zone, password}) do
    Process.flag(:trap_exit, true)
    schedule(0)
    {:ok, %{count: 0, user: user, zone: zone, password: password, update: 0}}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop unknown call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, "badreq"}, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop unknown cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:update_zone, state) do
    {user, zone, password} = Skn.Config.get(:proxy_account)
    {:noreply, %{state | user: user, zone: zone, password: password}}
  end

  def handle_info(:do_schedule, %{count: 0, user: user, update: update} = state) do
    count = Skn.Config.get(:proxy_scanner_count, 5)
    count = if count > 64, do: 64, else: count
    proxy_super_country = Skn.Config.get(:proxy_super_country, [])
    #        Logger.debug "start #{count} process to scan super proxy"
    parent = self()

    for _ <- 1..count do
      spawn(fn ->
        seed = Skn.Config.get(:proxy_auth_seq_seed)
        rand = Skn.Config.gen_id(:proxy_super_seq2)

        acc =
          if is_list(proxy_super_country) and length(proxy_super_country) > 0 do
            cc = Enum.at(proxy_super_country, rem(count, length(proxy_super_country)))

            DNSEx.lookup(
              "customer-#{user}-session-#{seed}#{rand}-servercountry-#{cc}.zproxy.lum-superproxy.io"
            )
          else
            DNSEx.lookup("customer-#{user}-session-#{seed}#{rand}.zproxy.lum-superproxy.io")
          end

        send(parent, {:search_result, acc})
      end)
    end

    ts_now = :erlang.system_time(:millisecond)
    diff = ts_now - update
    old = Skn.Config.get(:proxy_super_update, 1200_000)

    if diff >= old do
      ProxyGroup.update_all()
      # sync to node
      try do
        cnodes = :erlang.nodes()
        nodes = Skn.Config.get(:slaves, [])
        cnodes = Enum.filter(cnodes, fn x -> List.keyfind(nodes, x, 0) != nil end)

        Enum.each(cnodes, fn x ->
          Skn.DB.ProxyList.sync_super(x)
        end)
      catch
        _, exp ->
          Logger.error("sync super proxy failed #{exp}")
      end

      {:noreply, %{state | count: count, update: ts_now}}
    else
      {:noreply, %{state | count: count}}
    end
  end

  def handle_info(
        {:search_result, proxies},
        %{count: count, user: user, zone: zone, password: password} = state
      ) do
    #        Logger.debug "received #{length(proxies)} may be worked proxy"
    if count <= 1 do
      schedule(Skn.Config.get(:tm_proxy_scanner, 60000))
    end

    Enum.reduce(proxies, 0, fn x, acc ->
      tag = :super
      proxy = "http://#{x}:22225"
      proxy_auth = {:sessioner, "lum-customer-#{user}-zone-#{zone}", password}

      incr =
        case ping(x) do
          true -> 0
          false -> 1
        end

      Skn.DB.ProxyList.update_failed(%{id: {proxy, proxy_auth}, ip: x, incr: incr, tag: tag})
      acc + 1
    end)

    {:noreply, %{state | count: count - 1}}
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
  end

  def schedule(iv) do
    reset_timer(:schedule_ref, :do_schedule, iv)
  end

  def ping(ip) do
    opts = [
      {:linger, {false, 0}},
      {:insecure, true},
      {:pool, false},
      {:connect_timeout, 30000},
      {:recv_timeout, 90000},
      {:ssl_options, [{:versions, [:"tlsv1.2"]}, {:reuse_sessions, false}]}
    ]

    try do
      case HTTPoison.request(:get, "http://#{ip}:22225/ping", "", [], [{:hackney, opts}]) do
        {:ok, ret} ->
          if ret.status_code == 200 do
            x = Poison.decode!(decode_gzip(ret))
            svc = Map.get(x, "svc", %{})
            Map.get(svc, "has_internet", 0) == 1
          else
            false
          end

        _ ->
          false
      end
    catch
      _, _ -> false
    end
  end
end
