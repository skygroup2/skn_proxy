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
    {user, zone, password} = Skn.Config.get(:lum_proxy_account)
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
      proxy = "http://#{x}:22225"
      proxy_auth = {:lum, user, password, zone}

      incr =
        case ping(x) do
          true -> 0
          false -> 1
        end

      Skn.DB.ProxyList.update_failed(%{id: {proxy, proxy_auth}, ip: x, incr: incr, tag: :super})
      acc + 1
    end)

    {:noreply, %{state | count: count - 1}}
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
  end

  def schedule(iv) do
    reset_timer(:schedule_ref, :do_schedule, iv)
  end

  def ping(ip) do
    opts = %{
      recv_timeout: 25000,
      connect_timeout: 35000,
      retry: 0,
      retry_timeout: 5000,
      transport_opts: [{:reuseaddr, true}, {:reuse_sessions, false}, {:linger, {false, 0}}, {:versions, [:"tlsv1.2"]}]
    }

    try do
      case GunEx.http_request("GET", "http://#{ip}:22225/ping", %{"connection" => "close"}, "", opts, nil) do
        {:ok, ret} ->
          if ret.status_code == 200 do
            x = Jason.decode!(GunEx.decode_gzip(ret))
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
