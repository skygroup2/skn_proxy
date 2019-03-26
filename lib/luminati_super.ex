defmodule Luminati.Super do
  @moduledoc """
      scan super proxy
  """
  use GenServer
  require Logger
  @name :lum_super
  import Skn.Util,
    only: [
      reset_timer: 3
    ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: @name)
  end

  def init({user, zone, password}) do
    Process.flag(:trap_exit, true)
    reset_timer(:check_tick_ref, :check_tick, 20000)
    {:ok, %{count: 0, user: user, zone: zone, password: password}}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, :badreq}, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:update_zone, state) do
    {user, zone, password} = Skn.Config.get(:lum_proxy_account)
    {:noreply, %{state | user: user, zone: zone, password: password}}
  end

  def handle_info(:check_tick, %{count: 0, user: user} = state) do
    count = Skn.Config.get(:lum_proxy_max_scanner, 5)
    count = if count > 64, do: 64, else: count
    parent = self()
    for _ <- 1..count do
      spawn(fn ->
        rand = Skn.Config.gen_id(:proxy_super_seq2)

        acc =
          DNSEx.lookup("customer-#{user}-session-#{rand}.zproxy.lum-superproxy.io")
        send(parent, {:search_result, acc})
      end)
    end

    {:noreply, %{state | count: count}}
  end

  def handle_info({:search_result, proxies},
        %{count: count, user: user, zone: zone, password: password} = state) do
    if count <= 1 do
      reset_timer(:check_tick_ref, :check_tick, Skn.Config.get(:tm_lum_super_scan, 60000))
    end

    Enum.reduce(proxies, 0, fn x, acc ->
      proxy = "http://#{x}:22225"
      proxy_auth = {:lum, "lum-customer-#{user}-zone-#{zone}", password}

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
    Logger.debug("drop info #{inspect(msg)}")
    {:noreply, state}
  end

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
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
        ret when is_map(ret) ->
          if ret.status_code == 200 do
            x = Jason.decode!(GunEx.decode_gzip(ret))
            x["ip"] != nil
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
