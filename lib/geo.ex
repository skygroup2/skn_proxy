defmodule GeoIP do
  @moduledoc """
      check and update geo ip for static proxy
  """
  use GenServer
  require Logger
  alias Skn.Proxy.SqlApi
  import GunEx,
    only: [
      decode_gzip: 1,
      http_request: 6
    ]

  import Skn.Util,
    only: [
      reset_timer: 3
    ]

  @name :proxy_geo

  def update({requester, ip, keeper}, is_static) do
    flag = case SqlApi.get_GeoIP(ip) do
    %{geo: %{"country" => cc, "ip" => xip}} ->
        send requester, {:update_geo, ip, keeper, %{"country" => String.downcase(cc), "ip" => xip}, is_static}
        true
    _ ->
       false
    end
    if flag == false do
        GenServer.cast(@name, {:queue, {requester, ip, keeper}, is_static})
    end
  end

  def update(p, is_static) when is_map(p) do
    ip = p[:ip]

    if is_static == true or is_static == :unstable do
      flag =
        case SqlApi.get_GeoIP(ip) do
          %{geo: %{"country" => cc, "ip" => xip}} ->
            p_attrs =
              Map.merge(normalize_hog(p), %{
                real_ip: xip,
                country: String.downcase(cc),
                status: SqlApi.proxy_status_geo()
              })

            SqlApi.update_proxy(p_attrs)
            true

          _ ->
            false
        end

      if flag == false do
        GenServer.cast(@name, {:queue, p, is_static})
      end
    else
      :ignore
    end
  end

  def update(_m, _is_static) do
    :ignore
  end

  def normalize_geo(resp) do
    resp
  end

  def compress_geo(geo) do
    %{"country" => String.downcase(geo["country"]), "ip" => geo["ip"]}
  end

  def normalize_hog(x) do
    case x do
      %{address: address, port: port, protocol: protocol} ->
        %{address: address, port: port, protocol: protocol, zone: "unstable"}

      %{id: {{:socks5, a, port}, _}} ->
        address = :erlang.iolist_to_binary(:inet.ntoa(a))
        %{address: address, port: port, protocol: "socks5", zone: "s5", connect: 1, info: %{}}

      %{id: {<<"http://", address::binary>>, nil}} ->
        [a, p] = :binary.split(address, ":")

        %{
          address: a,
          port: :erlang.binary_to_integer(p),
          protocol: "http",
          zone: "lum",
          connect: 1,
          info: %{}
        }

      _ ->
        # Don't update luminati to hog
        %{}
    end
  end

  def query_by_vpn({proxy, proxy_auth}) do
    url = "http://lumtest.com/myip.json"

    headers = %{
      "accept-encoding" => "gzip",
      "connection" => "close"
    }

    try do
      proxy_opts = add_proxy_option(proxy, proxy_auth, default_proxy_option())

      case http_request("GET", url, headers, "", proxy_opts, nil) do
        response when is_map(response) ->
          if response.status_code == 200 do
            r = Jason.decode!(decode_gzip(response))
            normalize_geo(r)
          else
            Logger.error("GeoIP #{inspect print_proxy(proxy)} => #{inspect response.status_code}")
            {:error, response.status_code}
          end

        {:error, reason} when reason in [:timeout, :connect_timeout, :proxy_error, :econnrefused, :ehostunreach] ->
          case proxy do
            {:socks5, h, _p} ->
              query_by_ip(:inet.ntoa(h))
            _ ->
              {:error, reason}
          end
        exp ->
          Logger.error("GeoIP #{inspect print_proxy(proxy)} => #{inspect exp}")
          {:error, exp}
      end
    catch
      _, exp ->
        Logger.error("GeoIP #{inspect print_proxy(proxy)} => #{inspect System.stacktrace()}")
        {:error, exp}
    end
  end

  def query_by_ip(ip) do
    url = "http://lumtest.com/myip.json"

    headers = %{
      "x-forwarded-for" => ip,
      "accept-encoding" => "gzip",
      "connection" => "close"
    }

    try do
      case http_request("GET", url, headers, "", default_proxy_option(), nil) do
        response when is_map(response) ->
          if response.status_code == 200 do
            r = Jason.decode!(decode_gzip(response))
            normalize_geo(r)
          else
            {:error, response.status_code}
          end

        exp ->
          {:error, exp}
      end
    catch
      _, exp ->
        Logger.error("trace #{inspect(System.stacktrace())}")
        {:error, exp}
    end
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def init(_args) do
    Process.flag(:trap_exit, true)
    reset_timer(:schedule_ref, :schedule, 5000)
    {:ok, %{q: []}}
  end

  def handle_call({:stop, _}, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop unknown #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, :badreq}, state}
  end

  def handle_cast({:queue, ip, is_static}, %{q: q} = state) do
    {:noreply, %{state | q: [{ip, is_static} | q]}}
  end

  def handle_cast(request, state) do
    Logger.warn("drop unknown#{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:schedule, %{q: q} = state) do
    {q1, q2} =
      if length(q) > 5 do
        q1 = Enum.slice(q, -5, 5)
        {q1, Enum.slice(q, 0, length(q) - 5)}
      else
        {q, []}
      end

    q2x =
      Enum.reduce(q1, q2, fn {x, s}, acc ->
        case x do
          %{id: proxy_id} ->
            flag =
              case SqlApi.get_GeoIP(x[:ip]) do
                %{geo: %{"country" => cc, "ip" => xip}} ->
                  p_attrs =
                    Map.merge(normalize_hog(x), %{
                      real_ip: xip,
                      country: String.downcase(cc),
                      status: SqlApi.proxy_status_geo()
                    })

                  SqlApi.update_proxy(p_attrs)
                  true

                _ ->
                  case Skn.DB.ProxyList.get(proxy_id) do
                    %{info: %{failed: 0}} ->
                      false
                    _ ->
                      true
                  end
              end

            if flag == false do
              #                    Logger.debug "updating #{x[:ip]} #{s} GEO"
              geo = query_by_vpn(proxy_id)

              if is_map(geo) do
                SqlApi.update_GeoIP(%{
                  address: geo["ip"],
                  country: String.downcase(geo["country"]),
                  geo: geo
                })

                p_attrs =
                  Map.merge(normalize_hog(x), %{
                    real_ip: geo["ip"],
                    country: String.downcase(geo["country"]),
                    status: SqlApi.proxy_status_geo()
                  })

                SqlApi.update_proxy(p_attrs)

                if s == true do
                  Skn.DB.ProxyList.update_geo(x[:ip], compress_geo(geo))
                end

                acc
              else
                p_attrs =
                  Map.merge(normalize_hog(x), %{status: SqlApi.proxy_status_no_geo()})

                SqlApi.update_proxy(p_attrs)
                acc
              end
            else
              acc
            end

          {requester, ip, keeper} ->
            # Luminati keeper
            flag =
              case SqlApi.get_GeoIP(ip) do
                %{geo: %{"country" => cc, "ip" => xip}} ->
                  send(
                    requester,
                    {:update_geo, ip, keeper, %{"country" => String.downcase(cc), "ip" => xip}, false}
                  )

                  true

                _ ->
                  false
              end

            if flag == false do
              #                    Logger.debug "updating #{ip} #{s} GEO"
              geo = query_by_ip(ip)

              if is_map(geo) do
                SqlApi.update_GeoIP(%{
                  address: geo["ip"],
                  country: String.downcase(geo["country"]),
                  geo: geo
                })

                send(requester, {:update_geo, ip, keeper, compress_geo(geo), false})

                if s == true do
                  Skn.DB.ProxyList.update_geo(x[:ip], compress_geo(geo))
                end

                acc
              else
                acc
              end
            else
              acc
            end
        end
      end)

    if q2x != q2 do
      reset_timer(:schedule_ref, :schedule, 75000)
    else
      reset_timer(:schedule_ref, :schedule, 5000)
    end

    q2x = :sets.to_list(:sets.from_list(q2x))
    {:noreply, %{state | q: q2x}}
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

  defp add_proxy_option(proxy, proxy_auth, opts) do
    case proxy do
      nil ->
        opts
      _ ->
        Map.merge(opts, %{proxy: proxy, proxy_auth: proxy_auth})
    end
  end

  defp default_proxy_option() do
    %{
      recv_timeout: 25000,
      connect_timeout: 35000,
      retry: 0,
      retry_timeout: 5000,
      transport_opts: [{:reuseaddr, true}, {:reuse_sessions, false}, {:linger, {false, 0}}, {:versions, [:"tlsv1.2"]}]
    }
  end

  defp print_proxy(proxy) do
    case proxy do
      {:socks5, h, p} ->
        hs = :inet.ntoa(h)
        "socks5:#{hs}:#{p}"
      _ ->
        proxy
    end
  end
end
