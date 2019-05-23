defmodule ProxySizeDetector do
  @name :proxy_size_detector
  use GenServer
  require Logger
  import Skn.Util, only: [reset_timer: 3, cancel_timer: 2, dict_timestamp_check: 2]
  import Supervisor.Spec
  alias Skn.Proxy.SqlApi

  def start_luminati() do
    {:ok, _} = Supervisor.start_child(:proxy_sup, supervisor(Skn.Proxy.Repo, []))
    Skn.Proxy.Sup.start_proxy_super()
    opts = [id: __MODULE__, function: :start_link, restart: :transient, shutdown: 5000, modules: [__MODULE__]]
    {:ok, _} = Supervisor.start_child(:proxy_sup, worker(__MODULE__, [], opts))
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def init(_args) do
    Process.flag(:trap_exit, true)
    create_db()
    Skn.Counter.create_db()
    {:ok, %{workers: %{}}}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, :badreq}, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:pause, state) do
    cancel_timer(:check_tick_ref, :check_tick)
    {:noreply, state}
  end

  def handle_info(:check_tick, %{workers: workers} = state) do
    reset_timer(:check_tick_ref, :check_tick, 20000)
    if dict_timestamp_check(:ts_update_proxy, 300_000) do
      super_proxy = Skn.DB.ProxyList.list_tag(:super)
      Enum.each(super_proxy, fn x ->
        {proxy, proxy_auth} = x.id
        update_proxy(proxy, proxy_auth, 0)
      end)
    end
    max_worker = Skn.Config.get(:max_worker, 5)
    max_worker_request = Skn.Config.get(:max_worker_request, 20)
    parent = self()
    workers =
      Enum.reduce(get_proxy(max_worker - Map.size(workers)), workers, fn {proxy, proxy_auth}, acc ->
        if Map.get(workers, proxy, nil) == nil do
          pid = spawn(fn ->
            worker_proxy(proxy, proxy_auth, max_worker_request, parent)
          end)
          Map.put(acc, proxy, %{pid: pid, proxy: proxy, proxy_auth: proxy_auth})
        else
          acc
        end
      end)
    {:noreply, %{state| workers: workers}}
  end

  def handle_info({:finish, proxy, proxy_auth}, %{workers: workers} = state) do
    Logger.debug("proxy #{proxy} finished")
    update_proxy(proxy, proxy_auth, 1)
    {:noreply, %{state| workers: Map.delete(workers, proxy)}}
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

  def worker_proxy(proxy, proxy_auth, max_request, parent\\ nil) do
    try do
      cc_chunks = Enum.shuffle(country_codes()) |> Enum.chunk_every(max_request)
      Enum.each cc_chunks, fn cc_chunk ->
        pre_result = Enum.map(cc_chunk, fn cc ->
          Task.async(__MODULE__, :request_geoip, [proxy, proxy_auth, cc])
        end)
        result = Enum.map(pre_result, fn x -> Task.yield(x, 75000) end)
        Enum.reduce(result, [], fn x, acc ->
          case x do
            {:ok, geoip} when is_map(geoip) ->
              [geoip| acc]
            _ ->
              acc
          end
        end) |> Enum.uniq() |> SqlApi.insert_GeoIP_bulk()
      end
    catch
      _, exp ->
        Logger.debug("worker dead (#{inspect exp}) #{inspect(__STACKTRACE__)}")
        false
    end
    if parent != nil, do: send(parent, {:finish, proxy, proxy_auth})
  end

  def create_db() do
    # {{cnt, proxy}, proxy_auth}
    case :ets.info(@name) do
      :undefined ->
        :ets.new(@name, [ :public, :ordered_set, :named_table, {:read_concurrency, true}, {:write_concurrency, true} ])
      _ ->
        :ok
    end
  end

  def get_proxy(proxy_num) do
    if proxy_num > 0 do
      ms = [{:"$1", [], [:"$1"]}]
      case :ets.select(@name, ms, proxy_num) do
        {v, _} ->
          Enum.map(v, fn {{_, proxy}, proxy_auth} -> {proxy, proxy_auth} end)
        _ ->
          []
      end
    else
      []
    end
  end

  def update_proxy(proxy, proxy_auth, incr) do
    case :ets.match_object(@name, {{:_, proxy}, :_}) do
      [{{cnt, _}, _}] when incr > 0 ->
        :ets.delete(@name, {cnt, proxy})
        :ets.insert(@name, {{cnt + 1, proxy}, proxy_auth})
      [] ->
        :ets.insert(@name, {{0, proxy}, proxy_auth})
      _ ->
        :ok
    end
  end

  def request_geoip(proxy, proxy_auth, cc) do
    url = "http://lumtest.com/myip.json"
    headers = %{
      "accept-encoding" => "gzip",
      "connection" => "close"
    }
    try do
      proxy_opts = GeoIP.add_proxy_option(proxy, format_proxy_auth(proxy_auth, cc), GeoIP.default_proxy_option())
      case GunEx.http_request("GET", url, headers, "", proxy_opts, nil) do
        response when is_map(response) ->
          if response.status_code == 200 do
            Jason.decode!(GunEx.decode_gzip(response))
          else
            {:error, response.status_code}
          end
        {:error, reason} ->
          {:error, reason}
      end
    catch
      _, exp ->
        Logger.error("Query GeoIP #{proxy} => #{inspect System.stacktrace()}")
        {:error, exp}
    end
  end

  defp format_proxy_auth(proxy_auth, cc) do
    case proxy_auth do
      {:lum, x, y} ->
        rnd = Skn.Config.gen_id(:lum_proxy_auth_seq)
        {"#{x}-country-#{cc}-session-glob_rand#{rnd}", y}
      x ->
        x
    end
  end

  def country_codes() do
    [
      "af", "ax", "al", "dz", "as", "ad", "ao", "ai", "aq", "ag", "ar", "am", "aw", "au", "at", "az", "bs", "bh", "bd", "bb", "by", "be", "bz", "bj", "bm", "bt", "bo", "bq", "ba", "bw", "bv", "br", "io", "bn", "bg", "bf", "bi", "cv", "kh",
      "cm", "ca", "ky", "cf", "td", "cl", "cn", "cx", "cc", "co", "km", "cg", "cd", "ck", "cr", "ci", "hr", "cu", "cw", "cy", "cz", "dk", "dj", "dm", "do", "ec", "eg", "sv", "gq", "er", "ee", "sz", "et", "fk", "fo", "fj", "fi", "fr", "gf",
      "pf", "tf", "ga", "gm", "ge", "de", "gh", "gi", "gr", "gl", "gd", "gp", "gu", "gt", "gg", "gn", "gw", "gy", "ht", "hm", "va", "hn", "hk", "hu", "is", "in", "id", "ir", "iq", "ie", "im", "il", "it", "jm", "jp", "je", "jo", "kz", "ke",
      "ki", "kp", "kr", "kw", "kg", "la", "lv", "lb", "ls", "lr", "ly", "li", "lt", "lu", "mo", "mg", "mw", "my", "mv", "ml", "mt", "mh", "mq", "mr", "mu", "yt", "mx", "fm", "md", "mc", "mn", "me", "ms", "ma", "mz", "mm", "na", "nr", "np",
      "nl", "nc", "nz", "ni", "ne", "ng", "nu", "nf", "mk", "mp", "no", "om", "pk", "pw", "ps", "pa", "pg", "py", "pe", "ph", "pn", "pl", "pt", "pr", "qa", "re", "ro", "ru", "rw", "bl", "sh", "kn", "lc", "mf", "pm", "vc", "ws", "sm", "st",
      "sa", "sn", "rs", "sc", "sl", "sg", "sx", "sk", "si", "sb", "so", "za", "gs", "ss", "es", "lk", "sd", "sr", "sj", "se", "ch", "sy", "tw", "tj", "tz", "th", "tl", "tg", "tk", "to", "tt", "tn", "tr", "tm", "tc", "tv", "ug", "ua", "ae",
      "gb", "us", "um", "uy", "uz", "vu", "ve", "vn", "vg", "vi", "wf", "eh", "ye", "zm", "zw"
    ]
  end

end