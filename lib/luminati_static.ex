defmodule Luminati.Static do
  @moduledoc """
      Manager scanning static ip addr for luminati.io
  """
  use GenServer
  require Logger

  import HackneyEx,
    only: [
      decode_gzip: 1,
      send_rest: 5
    ]

  import Skn.Util,
    only: [
      check_ipv4: 1,
      reset_timer: 3
    ]

  @name :proxy_static
  @proxy_opts [
    {:linger, {false, 0}},
    {:insecure, true},
    {:pool, false},
    {:recv_timeout, 30000},
    {:connect_timeout, 30000}
  ]

  def start_link(check) do
    GenServer.start_link(__MODULE__, check, name: @name)
  end

  def refresh_ip(email, password, account, zone, ips) do
    url = "https://luminati.io/api/refresh"
    proxy_opts = [{:hackney, @proxy_opts}]

    headers = %{
      "Connection" => "close",
      "Content-Type" => "application/json"
    }

    body =
      Poison.encode!(%{email: email, password: password, customer: account, zone: zone, ips: ips})

    ret = HTTPoison.request(:post, url, body, headers, proxy_opts)

    case ret do
      {:ok, response} ->
        ips = :binary.split(decode_gzip(response), "\n", [:global])

        Enum.filter(ips, fn x ->
          case check_ipv4(x) do
            {true, :public} ->
              true

            _ ->
              false
          end
        end)

      _ ->
        Logger.error("refresh exception #{inspect(ret)}")
        []
    end
  end

  def list({u, z, p}, is_china \\ false) do
    url =
      if is_china == true do
        "https://luminati-china.io/api/get_route_ips?"
      else
        "https://luminati.io/api/get_route_ips?"
      end

    headers = %{
      "X-Hola-Auth" => "lum-customer-#{u}-zone-#{z}-key-#{p}",
      "Accept-Encoding" => "gzip",
      "Connection" => "close"
    }

    try do
      proxy_opts = @proxy_opts

      case send_rest(:get, url, "", headers, [{:hackney, proxy_opts}]) do
        {:ok, response} ->
          if response.status_code == 200 do
            ips = :binary.split(decode_gzip(response), "\n", [:global])

            Enum.filter(ips, fn x ->
              case check_ipv4(x) do
                {true, :public} ->
                  true

                _ ->
                  false
              end
            end)
          else
            []
          end

        _ ->
          []
      end
    catch
      _, _ ->
        []
    end
  end

  def init(check) do
    Process.flag(:trap_exit, true)
    reset_timer(:schedule_ref, :schedule, 120_000)
    {:ok, %{count: 0, checker: check}}
  end

  def handle_call({:stop, _}, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop unknown call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, "badreq"}, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop unknown cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:schedule, state) do
    Logger.debug("schedule to check and update ...")
    count = Skn.Config.get(:proxy_scanner_count, 5)
    count = if count > 15, do: 15, else: count

    proxy_static =
      Skn.Config.get(:proxy_account_static, [{"federico", "static", "mfotk5mb17iq"}])

    is_china = Skn.Config.get(:is_china, false)

    ips =
      Enum.concat(
        Enum.map(proxy_static, fn {u, z, p} ->
          ips0 = list({u, z, p}, is_china)

          if length(ips0) > 0 do
            indb = Skn.DB.ProxyList.list_tag_zone(:static, z)

            Enum.each(indb, fn x ->
              if x[:ip] in ips0 == false do
                #                        info1 = Map.merge(x[:info], %{status: :refresh, failed: 5})
                #                        x1 = Map.put x, :info, info1
                #                        Skn.DB.ProxyList.write(x1)
                Skn.DB.ProxyList.delete(x[:id])
              end
            end)
          end

          Enum.map(ips0, fn x0 ->
            id =
              if is_china == true do
                {"http://zproxy.luminati-china.io:22225",
                 {"lum-customer-#{u}-zone-#{z}-ip-#{x0}", p}}
              else
                {"http://zproxy.luminati.io:22225", {"lum-customer-#{u}-zone-#{z}-ip-#{x0}", p}}
              end

            %{id: id, ip: x0, tag: :static, info: %{zone: z}}
          end)
        end)
      )

    Enum.each(ips, fn x ->
      case Skn.DB.ProxyList.get(x[:id]) do
        nil ->
          Skn.DB.ProxyList.update_counter(Map.merge(x, %{incr: 1}), :failed)

        _ ->
          :ignore
      end
    end)

    reset_timer(:schedule_ref, :schedule, Skn.Config.get(:tm_proxy_scanner2, 350_000))
    {:noreply, %{state | count: count}}
  end

  def handle_info({:EXIT, _, _}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
  end

  def validate_static_proxy(handle, proxies) do
    ts_now = :erlang.system_time(:millisecond)
    tm_proxy_failed = Skn.Config.get(:tm_proxy_failed, 1_200_000)
    tm_proxy_banned = Skn.Config.get(:tm_proxy_banned, 86_400_000)
    tm_proxy_recheck = Skn.Config.get(:tm_proxy_recheck, 172_800_000)

    news =
      Enum.filter(proxies, fn proxy ->
        case Skn.DB.ProxyList.get(proxy[:id]) do
          %{info: %{status: :refresh}} ->
            false

          %{info: %{status: :banned, updated: updated}} when ts_now - updated < tm_proxy_banned ->
            false

          %{info: %{failed: failed, updated: updated}}
          when failed > 2 and ts_now - updated < tm_proxy_failed ->
            false

          %{info: %{status: :banned, failed: failed}} when failed < 2 ->
            false

          %{info: %{failed: failed}} when failed < 2 ->
            true

          nil ->
            true

          _ ->
            case Skn.DB.ProxyIP2.read(proxy[:ip]) do
              %{info: %{status: :ok, updated: updated}}
              when ts_now - updated < tm_proxy_recheck ->
                false

              %{info: %{status: :banned, banned: banned}}
              when ts_now - banned < tm_proxy_banned ->
                false

              _ ->
                true
            end
        end
      end)

    rets =
      Enum.map(news, fn proxy ->
        Task.async(fn ->
          ip = proxy[:ip]
          {p, pa} = proxy[:id]

          try do
            if handle != nil do
              handle.(proxy, %{proxy: p, proxy_auth: pa})
            else
              {:ok, proxy}
            end
          catch
            _, {:change_ip, {401, "AuthenticationException"} = exp} ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              Luminati.Keeper.update(ip, :banned)
              GeoIP.update(proxy, true)
              Skn.DB.ProxyList.set_info(proxy, :status, :banned)
              {:error, proxy}

            _, {:change_ip, {502, []} = exp} ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              Luminati.Keeper.update(ip, :banned)
              GeoIP.update(proxy, true)
              Skn.DB.ProxyList.set_info(proxy, :status, :banned)
              {:error, proxy}

            _, {:change_ip, exp} ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              Luminati.Keeper.update(ip, :banned)
              GeoIP.update(proxy, true)
              {:error, proxy}

            _, {502, []} = exp ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              Luminati.Keeper.update(ip, :banned)
              GeoIP.update(proxy, true)
              Skn.DB.ProxyList.set_info(proxy, :status, :banned)
              {:error, proxy}

            _, exp ->
              Logger.debug("proxy #{inspect(ip)} blocked by #{inspect(exp)}")
              #                    Luminati.Keeper.update(ip, :banned)
              GeoIP.update(ip, true)
              {:error, proxy}
          end
        end)
      end)

    status =
      Enum.map(rets, fn x ->
        Task.yield(x, 150_000)
      end)

    Enum.filter(status, fn x ->
      case x do
        {:ok, {:ok, y}} ->
          GeoIP.update(y, true)
          y1 = Map.put(y, :incr, 0)
          Skn.DB.ProxyList.update_failed(y1)
          false

        {:ok, {:error, _y}} ->
          #                incr = Map.get(y[:info], :incr, 0) + 1
          #                y1 = Map.put y, :incr, incr
          #                Skn.DB.ProxyList.update_failed(y1)
          true

        _ ->
          false
      end
    end)
  end
end
