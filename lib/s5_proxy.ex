defmodule S5Proxy do
  @moduledoc """
      check and parse s5 proxy, failed sync keeper
  """
  use GenServer
  require Logger

  import Skn.Util,
    only: [
      reset_timer: 3
    ]

  @name :s5_proxy

  def update_adsl(rec) do
    GenServer.cast(@name, {:update_adsl, rec})
  end

  def start_link(check) do
    GenServer.start_link(__MODULE__, check, name: @name)
  end

  def init(check) do
    Process.flag(:trap_exit, true)
    reset_timer(:schedule_ref, :schedule, 120_000)
    {:ok, %{count: 0, checker: check}}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, :badarg}, state}
  end

  def handle_cast({:update_adsl, rec}, state) do
    try_to_update_adsl(rec)
    {:noreply, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:force_schedule, state) do
    send(self(), :schedule)
    Process.put(:ts_update_geo, 0)
    {:noreply, state}
  end

  def handle_info({:update_adsl, _oip, _nip, _port}, state) do
    {:noreply, state}
  end

  def handle_info(:schedule, state) do
    ts_now = :erlang.system_time(:millisecond)
    ts_update_geo = Process.get(:ts_update_geo, 0)

    if ts_now - ts_update_geo > 1200_000 do
      ips = Skn.DB.ProxyList.list_tag_by_failed(:static)
      send(self(), {:update, ips})
      Process.put(:ts_update_geo, ts_now)
    end

    reset_timer(:schedule_ref, :schedule, 120_000)
    {:noreply, state}
  end

  def handle_info({:update, ips}, %{checker: handle} = state) do
    Logger.debug("update #{length(ips)} s5 proxy")
    ips = Enum.chunk_every(ips, 50)
    new = Enum.reduce(ips, 0, fn x, acc ->
      n = validate_static_proxy(handle, x)
      acc + n
    end)
    if new > Skn.Config.get(:update_static_new, 100) do
      ProxyGroup.update_static()
      if Skn.Config.get(:sync_static, false) == true do
        Skn.DB.ProxyList.sync_static()
      end
    end
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, :normal}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("drop #{inspect(msg)}")
    {:noreply, state}
  end

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
  end

  def try_to_update_adsl(%{ssh_ip: ssh_ip, ssh_port: ssh_port, tag: tag, ip: ip, port: port}) do
    try do
      {:ok, naddr} = :inet.parse_ipv4_address(:erlang.binary_to_list(ip))
      ts_now = :erlang.system_time(:millisecond)
      i_tag = if tag == "" or tag == "static", do: :static, else: tag
      p = %{
        id: {{:socks5, naddr, port}, nil},
        ip: ip,
        tag: i_tag,
        assign: format_ssh_ip_assign(ssh_ip, ssh_port),
        info: %{updated: ts_now, geo: %{"country_code" => "cn", "ip" => ip}},
        incr: 0
      }

      case Skn.DB.ProxyList.get(p[:id]) do
        %{info: %{failed: 0}} ->
          :ok

        _ ->
          Skn.DB.ProxyList.delete_by_assign(p[:assign])
          Skn.DB.ProxyList.write(p)
          Skn.DB.ProxyDial.delete_by({:socks5, naddr, port}, p[:assign])
      end
    catch
      _, _ ->
        Logger.error(
          "update adsl #{ssh_ip}:#{ssh_port} => #{ip}:#{port} #{inspect(System.stacktrace())}"
        )

        :ok
    end
  end

  def try_to_update_adsl(_) do
    :ok
  end

  defp format_ssh_ip_assign(ssh_ip, ssh_port) do
    case :inet.parse_ipv4_address(:erlang.binary_to_list(ssh_ip)) do
      {:ok, _} when is_integer(ssh_port) and ssh_port > 0 ->
        "ADSL_#{ssh_ip}:#{ssh_port}"

      _ ->
        nil
    end
  end

  def validate_static_proxy(handle, proxies) do
    ts_now = :erlang.system_time(:millisecond)
    tm_proxy_failed = Skn.Config.get(:tm_proxy_failed, 1_200_000)
    tm_proxy_recheck = Skn.Config.get(:tm_proxy_recheck, 172_800_000)

    news =
      Enum.filter(proxies, fn proxy ->
        case Skn.DB.ProxyList.get(proxy[:id]) do
          %{info: %{status: :refresh}} ->
            false

          %{info: %{failed: failed, updated: updated}} when failed > 2 ->
            ts_now - updated >= min(failed - 1, 120) * tm_proxy_failed

          %{info: %{failed: 0, updated: updated}} ->
            (ts_now - updated) >= tm_proxy_recheck
          _ ->
            true
        end
      end)

    rets =
      Enum.map(news, fn proxy ->
        Task.async(fn ->
          ip = proxy[:ip]
          {p, pa} = proxy[:id]
          pi = proxy[:info][:proxy_remote]
          try do
            if handle != nil do
              handle.(proxy, %{proxy: p, proxy_auth: pa, proxy_remote: pi})
            else
              {:ok, proxy}
            end
          catch
            _, {:change_ip, exp} ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              Proxy.Keeper.update(ip, :banned)
              {:error, proxy}

            _, exp ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              Proxy.Keeper.update(ip, :banned)
              {:error, proxy}
          end
        end)
      end)

    status =
      Enum.map(rets, fn x ->
        Task.yield(x, 90_000)
      end)
    Enum.reduce(status, 0, fn (x, acc) ->
      case x do
        {:ok, {:ok, y}} ->
          GeoIP.update(y, true)
          y1 = Map.put(y, :incr, 0)
          Skn.DB.ProxyList.update_failed(y1)
          acc + 1
        {:ok, {:error, y}} ->
          GeoIP.update(y, true)
          y1 = Map.put(y, :incr, 1)
          Skn.DB.ProxyList.update_failed(y1)
          acc
        _ ->
          acc
      end
    end)
  end
end
