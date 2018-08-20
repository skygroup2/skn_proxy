defmodule S5Proxy do
  @moduledoc """
      check and parse s5 proxy, failed sync keeper
  """
  use GenServer
  require Logger

  import Skn.Util,
    only: [
      reset_timer: 3,
      split_list: 2
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

      Enum.each(ips, fn x ->
        if x[:info][:geo] == nil do
          GeoIP.update(x, true)
        end
      end)

      send(self(), {:update, ips})
      Process.put(:ts_update_geo, ts_now)
    end

    reset_timer(:schedule_ref, :schedule, 120_000)
    {:noreply, state}
  end

  def handle_info({:update, ips}, %{checker: handle} = state) do
    Logger.debug("update #{length(ips)} s5 proxy")
    ips = split_list(ips, 50)

    Enum.each(ips, fn x ->
      Luminati.Static.validate_static_proxy(handle, x)
    end)

    {:noreply, state}
  end

  def handle_info({:EXIT, _from, :normal}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("drop #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
  end

  def try_to_update_adsl(%{ssh_ip: ssh_ip, ssh_port: ssh_port, ip: ip, port: port}) do
    try do
      {:ok, naddr} = :inet.parse_ipv4_address(:erlang.binary_to_list(ip))
      ts_now = :erlang.system_time(:millisecond)

      p = %{
        id: {{:socks5, naddr, port}, nil},
        ip: ip,
        tag: :static,
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
          ProxyGroup.update_static()
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
end
