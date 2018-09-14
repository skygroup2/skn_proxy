defmodule ProxyOther do
  use GenServer
  require Logger
  import Skn.Util, only: [
    reset_timer: 3,
    check_ipv4: 1
  ]
  @name :proxy_other

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def init(_name) do
    Process.flag(:trap_exit, true)
    reset_timer(:check_tick_ref, :check_tick, 20000)
    {:ok, %{queue: :queue.new()}}
  end

  def handle_call(request, from, state) do
    Logger.error "drop unknown #{inspect request} from #{inspect from}"
    {:reply, {:error, :badreq}, state}
  end

  def handle_cast(cast, state) do
    Logger.error "drop unknown #{inspect cast}"
    {:noreply, state}
  end

  def handle_info(:check_tick, state) do
    try do
      case Skn.Config.get(:proxy_hulk_auth) do
        {username, password} ->
          grab_proxy_hulk(username, password) |> import_other_proxies()
        _ ->
          :ok
      end
      case Skn.Config.get(:proxy_fine_auth) do
        {username, password} ->
          grab_fine_proxy(username, password) |> import_other_proxies()
        _ ->
          :ok
      end
    catch
      _, exp ->
        Logger.error("update failed #{inspect exp}, #{inspect System.stacktrace()}")
    end
    reset_timer(:check_tick_ref, :check_tick, Skn.Config.get(:tm_proxy_other, 1200_000))
    {:noreply, state}
  end

  def handle_info(info, state) do
    Logger.error "drop unknown #{inspect info}"
    {:noreply, state}
  end

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.debug "stopped by #{inspect reason}"
    :ok
  end

  def grab_proxy_hulk(username, _password) do
    {:ok, x} = HTTPoison.get "https://www.proxyhulk.com/list/getmylist.php?type=socks&user=#{username}"
    <<239, 187, 191, body :: binary>> = x.body
    res = String.replace(body, "<br />", "")
    res2 = String.split(res, "\n")
    res3 = Enum.map res2, fn (x) ->
      case String.split(x, ":") do
        [x, y] -> {x, String.to_integer(y)}
        _ -> nil
      end
    end
    res4 = Enum.map res3, fn x ->
      case x do
        {ip, port} ->
          case check_ipv4(ip) do
            {true, :public} ->
              {:ok, addr} = :inet.parse_ipv4_address(:erlang.binary_to_list(ip))
              %{proxy: {:socks5, addr, port}, ip: ip, proxy_auth: nil, tag: :hulk}
            _ ->
              nil
          end
        _ ->
          nil
      end
    end
    Enum.filter res4, fn x -> is_map(x) end
  end

  def grab_fine_proxy(username, password) do
    {:ok, x} = HTTPoison.get "http://account.fineproxy.org/api/getproxy/?format=txt&type=socksip&login=#{username}&password=#{password}"
    res2 = :binary.split x.body, "\r\n", [:global]
    res3 = Enum.map res2, fn (x) ->
      case String.split(x, ":") do
        [x, y] -> {x, String.to_integer(y)}
        _ -> nil
      end
    end
    res4 = Enum.map res3, fn x ->
      case x do
        {ip, port} ->
          case check_ipv4(ip) do
            {true, :public} ->
              {:ok, addr} = :inet.parse_ipv4_address(:erlang.binary_to_list(ip))
              %{proxy: {:socks5, addr, port}, ip: ip, proxy_auth: nil, tag: :fineproxy}
            _ ->
              nil
          end
        _ ->
          nil
      end
    end
    Enum.filter res4, fn x -> is_map(x) end
  end

  defp import_other_proxies(proxies) do
    Enum.reduce proxies, 0, fn(%{proxy: proxy, proxy_auth: proxy_auth, ip: ip, tag: tag}, acc) ->
      case Skn.DB.ProxyList.get({proxy, nil}) do
      %{info: %{failed: 0}} ->
        acc
      nil ->
        r = %{id: {proxy, proxy_auth}, ip: ip, tag: :static, assign: tag, info: %{failed: 1}}
        Skn.DB.ProxyList.write(r)
        acc + 1
      _ ->
        acc
      end
    end
  end
end