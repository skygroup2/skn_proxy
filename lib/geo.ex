defmodule GeoIP do
  @moduledoc """
      check and update geo ip for static proxy
  """
  use GenServer
  require Logger
  alias Skn.Proxy.SqlApi
  import HackneyEx,
    only: [
      decode_gzip: 1,
      send_rest: 7
    ]

  import Skn.Util,
    only: [
      reset_timer: 3
    ]

  @name :proxy_geo
  @proxy_opts [
    {:linger, {false, 0}},
    {:insecure, true},
    {:pool, false},
    {:recv_timeout, 30000},
    {:connect_timeout, 30000}
  ]

  def update({_requester, _ip, _keeper}, _is_static) do
    #        flag = case SqlApi.get_GeoIP(ip) do
    #        %{geo: %{"country_code" => cc, "ip" => xip}} ->
    #            send requester, {:update_geo, ip, keeper, %{"country_code" => cc, "ip" => xip}, is_static}
    #            true
    #        _ ->
    #           false
    #        end
    #        if flag == false do
    #            GenServer.cast(@name, {:queue, {requester, ip, keeper}, is_static})
    #        end
    :ignore
  end

  def update(p, is_static) when is_map(p) do
    ip = p[:ip]

    if is_static == true or is_static == :unstable do
      flag =
        case SqlApi.get_GeoIP(ip) do
          %{geo: %{"country_code" => cc, "ip" => xip}} ->
            p_attrs =
              Map.merge(normalize_hog(p), %{
                real_ip: xip,
                country: cc,
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

  def normalize_geo(:freegeoip, resp) do
    x = Map.drop(resp, ["__deprecation_message__", "region_name", "metro_code", "country_name"])

    Map.merge(x, %{
      "country_code" => String.downcase(resp["country_code"]),
      "region_code" => String.downcase(resp["region_code"]),
      "asn" => %{}
    })
  end

  def normalize_geo(:luminati, resp) do
    x = Map.drop(resp, ["geo", "country"])
    geo = Map.get(resp, "geo", %{})
    gx = Map.drop(geo, ["tz", "region", "postal_code"])

    gxx =
      Map.merge(gx, %{
        "time_zone" => geo["tz"],
        "zip_code" => geo["postal_code"],
        "region_code" => String.downcase(geo["region"])
      })

    xx = Map.merge(x, %{"country_code" => String.downcase(resp["country"])})
    Map.merge(xx, gxx)
  end

  def compress_geo(geo) do
    %{"country_code" => geo["country_code"], "ip" => geo["ip"]}
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
      "Accept-Encoding" => "gzip",
      "Connection" => "close"
    }

    try do
      proxy_opts = add_proxy_option(proxy, proxy_auth, @proxy_opts)

      case send_rest(:get, url, "", headers, [{:hackney, proxy_opts}], 0, 2) do
        {:ok, response} ->
          if response.status_code == 200 do
            r = Poison.decode!(decode_gzip(response))
            normalize_geo(:luminati, r)
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

  def query_by_ip(ip) do
    url = "http://freegeoip.net/json/#{ip}"

    headers = %{
      "Accept-Encoding" => "gzip",
      "Connection" => "close"
    }

    try do
      proxy_opts = @proxy_opts ++ get_if()

      case send_rest(:get, url, "", headers, [{:hackney, proxy_opts}], 0, 2) do
        {:ok, response} ->
          if response.status_code == 200 do
            r = Poison.decode!(decode_gzip(response))
            normalize_geo(:freegeoip, r)
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
                %{geo: %{"country_code" => cc, "ip" => xip}} ->
                  p_attrs =
                    Map.merge(normalize_hog(x), %{
                      real_ip: xip,
                      country: cc,
                      status: SqlApi.proxy_status_geo()
                    })

                  SqlApi.update_proxy(p_attrs)
                  true

                _ ->
                  false
              end

            if flag == false do
              #                    Logger.debug "updating #{x[:ip]} #{s} GEO"
              geo = query_by_vpn(proxy_id)

              if is_map(geo) do
                SqlApi.update_GeoIP(%{
                  address: geo["ip"],
                  country: geo["country_code"],
                  geo: geo
                })

                p_attrs =
                  Map.merge(normalize_hog(x), %{
                    real_ip: geo["ip"],
                    country: geo["country_code"],
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
                %{geo: %{"country_code" => cc, "ip" => xip}} ->
                  send(
                    requester,
                    {:update_geo, ip, keeper, %{"country_code" => cc, "ip" => xip}, false}
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
                  country: geo["country_code"],
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

  def terminate(reason, _state) do
    Logger.debug("stopped by #{inspect(reason)}")
    :ok
  end

  defp get_if() do
    i = Skn.Counter.update_counter(:if_seq, 1)
    ips = Skn.Config.get(:ips, [])

    if ips == [] do
      []
    else
      ix = rem(i, length(ips))
      [{:connect_options, [{:ip, Enum.at(ips, ix)}]}]
    end
  end

  defp add_proxy_option(proxy, proxy_auth, opts) do
    proxy_opts =
      case proxy do
        nil ->
          []
        {:socks5, _, _} ->
          case proxy_auth do
            {user, pass} ->
              [{:proxy, proxy}, {:socks5_user, user}, {:socks5_pass, pass}]

            _ ->
              [{:proxy, proxy}]
          end
        proxy ->
          case proxy_auth do
            nil -> [{:proxy, proxy}]
            auth -> [{:proxy, proxy}, {:proxy_auth, auth}]
          end
      end

    proxy_opts = proxy_opts ++ get_if()
    proxy_opts ++ opts
  end
end
