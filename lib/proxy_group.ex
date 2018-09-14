defmodule ProxyGroup do
  @moduledoc """
      Manager a group of proxy, if proxy die, grab new one from database
  """
  use GenServer
  require Logger
  import Skn.Util, only: [
    reset_timer: 3
  ]

  @country_list [:ae , :af , :ag , :ai , :al , :am , :an , :ao , :aq , :ar , :as , :at , :au , :aw , :ax , :az , :ba , :bb , :bd , :be , :bf , :bg , :bh , :bi , :bj , :bl , :bm , :bn , :bo , :br , :bs , :bt , :bv , :bw , :by , :bz , :ca , :cc , :cd , :cf , :cg , :ch , :ci , :ck , :cl , :cm , :cn , :co , :cr , :cu , :cv , :cx , :cy , :cz , :de , :dj , :dk , :dm , :do , :dz , :ec , :ee , :eg , :eh , :er , :es , :et , :fi , :fj , :fk , :fm , :fo , :fr , :ga , :gb , :gd , :ge , :gf , :gg , :gh , :gi , :gl , :gm , :gn , :gp , :gq , :gr , :gs , :gt , :gu , :gw , :gy , :hk , :hm , :hn , :hr , :ht , :hu , :id , :ie , :il , :im , :in , :io , :iq , :ir , :is , :it , :je , :jm , :jo , :jp , :ke , :kg , :kh , :ki , :km , :kn , :kp , :kr , :kw , :ky , :kz , :la , :lb , :lc , :li , :lk , :lr , :ls , :lt , :lu , :lv , :ly , :ma , :mc , :md , :me , :mf , :mg , :mh , :mk , :ml , :mm , :mn , :mo , :mp , :mq , :mr , :ms , :mt , :mu , :mv , :mw , :mx , :my , :mz , :na , :nc , :ne , :nf , :ng , :ni , :nl , :no , :np , :nr , :nu , :nz , :om , :pa , :pe , :pf , :pg , :ph , :pk , :pl , :pm , :pn , :pr , :ps , :pt , :pw , :py , :qa , :re , :ro , :rs , :ru , :rw , :sa , :sb , :sc , :sd , :se , :sg , :sh , :si , :sj , :sk , :sl , :sm , :sn , :so , :sr , :ss , :st , :sv , :sy , :sz , :tc , :td , :tf , :tg , :th , :tj , :tk , :tl , :tm , :tn , :to , :tr , :tt , :tv , :tw , :tz , :ua , :ug , :um , :us , :uy , :uz , :va , :vc , :ve , :vg , :vi , :vn , :vu , :wf , :ws , :ye , :yt , :za , :zm , :zw]
  @country_black_list ["ai" , "an" , "ao" , "aq" , "as" , "bl" , "bv" , "cc" , "cf" , "cg" , "ck" , "cu" , "cx" , "dj" , "eh" , "er" , "fk" , "gs" , "gw" , "hm" , "io" , "ki" , "km" , "kp" , "kr" , "kz" , "li" , "ls" , "mf" , "mh" , "ms" , "mw" , "nf" , "nr" , "nu" , "pn" , "pw" , "sb" , "sc" , "sh" , "sj" , "sl" , "sm" , "ss" , "td" , "tf" , "tk" , "tl" , "to" , "tv" , "um" , "va" , "vg" , "vu" , "wf" , "ye" , "xk" , "cn" , "ru" , "tw" , "hk" , "il" , "dz" , "eg" , "id" , "in" , "ir" , "ma" , "pk" , "ps" , "sy" , "th" , "uy" , "tn" , "sa" , "sn" , "bi" , "st" , "gn" , "pg" , "ws" , "ne" , "mp" , "sz" , "lc" , "fm" , "rw" , "bf" , "cd" , "tm" , "lr" , "mr" , "cm" , "et" , "yt" , "az" , "so" , "pm" , "tg" , "vn" , "my" , "ua" , "tr" , "ec" , "do" , "om" , "vi" , "sx" , "kh" , "dm" , "ag" , "bt" , "mc" , "af" , "cv" , "gq" , "bw" , "bd" , "ga" , "gm" , "ml"]

  def force_country_black_list() do
    default = [ "as", "ad", "ai", "aq", "ag", "aw", "bs", "bh", "bb", "bz", "bm", "bt", "io", "vg", "bn", "cv", "ky", "cx", "cc", "ck", "cw", "dj", "dm", "fk", "fo", "pf", "gi", "gl", "gd", "gu", "gg", "gy", "is", "im", "je", "ki", "li", "lu", "mo", "mv", "mt", "mh", "yt", "fm", "mc", "me", "ms", "nr", "an", "nc", "nu", "mp", "pw", "pn", "bl", "sh", "kn", "lc", "mf", "pm", "vc", "ws", "sm", "st", "sc", "sx", "sb", "sr", "sj", "tk", "to", "tc", "tv", "vi", "vu", "va", "wf", "eh", "xk", "gq"]

    Skn.Config.get(:force_country_black_list, default)
  end

  def add_force_country_to_black_list(cc) do
    a = force_country_black_list()
    a1 = if cc in a, do: a, else: a ++ [cc]
    Skn.Config.set(:force_country_black_list, a1)
  end

  def force_replace_country_black_list(botid) do
    ips = Skn.Config.get(:proxy_ip_country_list)
    top = Enum.slice(Enum.sort_by(ips, fn {_, x} -> x * -1 end), 0, 5)
    i = rem(botid, length(top))
    {cc, _} = Enum.at(top, i)
    cc
  end

  def choose(config, botid, cc, idx \\ 0) do
    proxy = config[:proxy]
    proxy_auth = config[:proxy_auth]

    case proxy do
      {:group, id} ->
        ret = grab_proxy(proxy_to_name({id, nil}), botid, cc, idx)
        Map.merge(ret, %{proxy_auth: new_proxy_session(ret[:proxy_auth], botid, cc)})

      {:force, proxy, proxy_auth} ->
        %{
          proxy: proxy,
          proxy_auth: new_proxy_session(proxy_auth, botid, cc),
          proxy_auth_fun:
            {__MODULE__, :choose, [%{proxy: {:force, proxy, proxy_auth}}, botid, cc, idx]}
        }

      _ ->
        %{proxy: proxy, proxy_auth: new_proxy_session(proxy_auth, botid, cc)}
    end
  end

  def new_proxy_session(proxy_auth, botid, cc) do
    case proxy_auth do
      {:sessioner, x, y} ->
        seed = Skn.Config.get(:proxy_auth_seq_seed)
        rnd = Skn.Config.gen_id(:proxy_auth_seq)
        luminati_is_glob = Skn.Config.get(:luminati_is_glob, true)
        cc = bot_country(botid, cc)

        if luminati_is_glob == true do
          {"#{x}-country-#{cc}-session-glob_rand#{seed}#{rnd}", y}
        else
          {"#{x}-country-#{cc}-session-rand#{seed}#{rnd}", y}
        end

      x ->
        x
    end
  end

  def bot_country(id, cc) when is_integer(id) == false do
    if cc != nil do
      cc
    else
      bot_country(:erlang.phash2(id), cc)
    end
  end

  def bot_country(id, cc) do
    is_master = Skn.Config.get(:master) == node()

    cond do
      is_master and cc != nil ->
        cc

      is_master and is_integer(id) ->
        Enum.at(["us", "ca"], rem(id, 2))

      true ->
        force = force_country_black_list()

        cond do
          cc == nil ->
            s = Skn.Config.get(:proxy_ip_country_size, 1)

            case :ets.lookup(:proxy_country_percent, rem(id, s)) do
              [{_, cc}] -> cc
              [] -> Enum.at(["us", "ca"], rem(id, 2))
            end

          cc in force ->
            force_replace_country_black_list(id)

          true ->
            cc
        end
    end
  end

  def replace_banned_country(banned \\ @country_black_list) do
    c = :ets.tab2list(:proxy_country_percent)

    Enum.each(banned, fn x ->
      r = Enum.at(["us", "ca", "gb"], rem(:erlang.phash2(x), 3))
      rc = Enum.filter(c, fn {_, x1} -> x1 == x end)

      Enum.each(rc, fn {x2, c2} ->
        IO.puts("replace coutry #{c2} with #{r} at #{x2}")
        :ets.insert(:proxy_country_percent, {x2, r})
      end)
    end)
  end

  def find_banned_country(
        life \\ -1,
        filter \\ true,
        week \\ :all,
        level \\ 5,
        age \\ 5 * 3600_000
      ) do
    v = :ets.tab2list(:bans_report)
    ts_f = :erlang.system_time(:millisecond) - age

    v1 =
      Enum.filter(v, fn {{ts, _id}, info} ->
        ts > ts_f and ((is_integer(info[:life]) and info[:life] < life) or life == -1) and
          (info[:week] == week or week == :all) and (info[:level] == nil or info[:level] <= level)
      end)

    v2 =
      Enum.reduce(v1, %{}, fn {_k, info}, acc ->
        c = Map.get(acc, info[:cc], 0) + 1
        Map.put(acc, info[:cc], c)
      end)

    v3 = Map.to_list(v2)

    v3 =
      if filter == true do
        Enum.filter(v3, fn {x, _} -> not (String.downcase(x) in force_country_black_list()) end)
      else
        v3
      end

    Enum.sort_by(v3, fn {_, x} -> -x end)
  end

  def find_country_black(fun, each_try, decide_black) do
    country = @country_list

    ct =
      Enum.map(country, fn c ->
        Task.async(fn ->
          tasks =
            Enum.map(1..each_try, fn x ->
              Task.async(fn ->
                {x, fun.(c)}
              end)
            end)

          rets =
            Enum.map(tasks, fn x ->
              Task.yield(x, 300_000)
            end)

          {o, e} =
            Enum.reduce(rets, {0, 0}, fn x, {o0, e0} ->
              case x do
                {:ok, {_, :ok}} ->
                  {o0 + 1, e0}

                {:ok, _} ->
                  {o0, e0 + 1}

                exp ->
                  IO.puts("yeild error #{inspect(exp)}")
                  {o0, e0}
              end
            end)

          {c, o, e}
        end)
      end)

    cr =
      Enum.map(ct, fn x ->
        Task.yield(x, 300_000)
      end)

    Enum.reduce(cr, [], fn x, acc ->
      case x do
        {:ok, {c, _o, e}} ->
          if e >= decide_black do
            [if(is_binary(c), do: c, else: :erlang.atom_to_binary(c, :latin1)) | acc]
          else
            acc
          end

        exp ->
          IO.puts("yeild error #{inspect(exp)}")
          acc
      end
    end)
  end

  def calc_country_percent() do
    ipk = :mnesia.dirty_all_keys(:proxy_ip2)

    ips =
      Enum.reduce(ipk, %{}, fn ip, acc ->
        case Skn.DB.ProxyIP2.read(ip) do
          %{info: %{status: status, geo: %{"country_code" => cc}}} when byte_size(cc) == 2 ->
            if status == :ok do
              cc = String.downcase(cc)
              cn = Map.get(acc, cc, 0) + 1
              Map.put(acc, cc, cn)
            else
              acc
            end

          _ ->
            if byte_size(ip) >= 45 do
              Skn.DB.ProxyIP2.delete(ip)
            else
              IO.puts("#{inspect(ip)} country code ????")
            end

            acc
        end
      end)

    country_black_list = Skn.Config.get(:proxy_ip_country_black_list, @country_black_list)
    ips = Enum.filter(ips, fn {x, _} -> not (x in country_black_list) end)
    ipc = Enum.map(ips, fn {_, x} -> x end)
    itotal = Enum.sum(ipc)
    ips = Enum.sort_by(ips, fn {_cc, per} -> per end)

    ips =
      Enum.map(ips, fn {cc, per} ->
        cn = per / itotal
        {cc, cn}
      end)

    Enum.sort(ips)
  end

  def update_country_percent(ips \\ nil) do
    _ips =
      if ips != nil do
        c = Enum.map(ips, fn {_cc, cn} -> cn end)
        c = Enum.sum(c)
        Skn.Config.set(:proxy_ip_country_size, c)
        Skn.Config.set(:proxy_ip_country_list, ips)
        ips
      else
        Skn.Config.get(:proxy_ip_country_list, [{"us", 1}])
      end
  end

  def update_master_country_percent do
    :net_adm.ping(Skn.Config.get(:master))
    a = :rpc.call(Skn.Config.get(:master), Skn.DB.Config, :get, [:proxy_ip_country_list])
    update_country_percent(a)
  end

  def proxy_to_name({:choose, x}) do
    id = rem(Skn.Config.gen_id(:proxy_super_seq), groups()) + 1
    proxy_to_name({id, x})
  end

  def proxy_to_name({id, _}) do
    :erlang.list_to_atom('proxy_group_#{id}')
  end

  def update_all do
    proxies = Skn.DB.ProxyList.list_tag(:super)

    for id <- 1..groups() do
      GenServer.cast(proxy_to_name({id, nil}), {:update, proxies})
    end
  end

  def update_static() do
    proxies = Skn.DB.ProxyList.list_tag(:static)
    GenServer.cast(proxy_to_name({:static, nil}), {:update, proxies})
  end

  def remove_static_proxy(proxy) do
    GenServer.cast(proxy_to_name({:static, nil}), {:remove, proxy})
  end

  def groups do
    2
  end

  def get_group(id) do
    case id do
      :static -> :proxy_group_static
      _ -> proxy_to_name({id, nil})
    end
  end

  def grab_proxy(group, botid, cc, idx) do
    GenServer.call(group, {:get, botid, cc, idx}, 60000)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: proxy_to_name(args))
  end

  def stop_by(pid, reason) do
    try do
      GenServer.call(pid, {:stop, reason})
    catch
      _, _ ->
        :ignore
    end
  end

  def init({:static, group}) do
    Process.flag(:trap_exit, true)
    send(self(), {:update, group})
    tm_proxy_sync = Skn.Config.get(:tm_proxy_sync, 1200_000)
    reset_timer(:update_static_ref, :update_static, tm_proxy_sync)
    {:ok, %{id: :static, group: [], ptr: :rand.uniform(5000), cc: %{}}}
  end

  def init({id, group}) do
    Process.flag(:trap_exit, true)
    {:ok, %{id: id, group: group, ptr: 0, cc: %{}}}
  end

  def handle_call({:set, group}, _from, state) do
    {:reply, :ok, %{state | group: group}}
  end

  def handle_call({:get, botid, cc, idx}, _from, %{id: :static, cc: ccx, ptr: ptr} = state) do
    cck = ccx[:list]
    idxx = if idx == nil, do: ptr, else: idx
    cc = if cc == nil and is_list(cck) and cck != [], do: Enum.at(cck, rem(ptr, length(cck))), else: cc
    x =
      if is_list(cck) and cc in cck do
        c = cc
        pl = Map.get(ccx, c, [])
        if length(pl) > 0 do
          Enum.at(pl, rem(idxx, length(pl)))
        else
          nil
        end
      else
        nil
      end

    idxx2 = if idx == nil, do: idx, else: idx + 1

    proxy =
      case x do
        {:socks5, _} = p ->
          %{proxy: p}
        {p, a} ->
          %{
            proxy: p,
            proxy_auth: a,
            proxy_auth_fun: {__MODULE__, :choose, [%{proxy: {:group, :static}}, botid, cc, idxx2]}
          }
        _ ->
          %{proxy: nil, proxy_auth: nil}
      end
    ptr1 = if ptr + 1 > 999_999_999, do: :rand.uniform(5000), else: ptr + 1
    {:reply, proxy, %{state | ptr: ptr1}}
  end

  def handle_call({:get, botid, cc, idx}, _from, %{id: id, group: group} = state) do
    proxy =
      if length(group) > 0 do
        i = rem(:erlang.phash2(botid) + idx, length(group))
        proxy0 = Enum.at(group, i)

        case proxy0 do
          {:socks5, _} = p ->
            %{
              proxy: p,
              proxy_auth_fun: {__MODULE__, :choose, [%{proxy: {:group, id}}, botid, cc, idx + 1]}
            }

          {p, a} ->
            %{
              proxy: p,
              proxy_auth: a,
              proxy_auth_fun: {__MODULE__, :choose, [%{proxy: {:group, id}}, botid, cc, idx + 1]}
            }

          _ ->
            %{proxy: nil, proxy_auth: nil}
        end
      else
        %{proxy: nil, proxy_auth: nil}
      end

    {:reply, proxy, state}
  end

  def handle_call({:stop, _}, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop unknown call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, "badreq"}, state}
  end

  def handle_cast({:update, group}, %{id: :static} = state) do
    ts_now = :erlang.system_time(:millisecond)
    ts_updated = Process.get(:ts_updated, 0)
    if (ts_now - ts_updated) >= 20_000 do
      Process.get(:ts_updated, ts_now)
      s5_proxy_force_cc = Skn.Config.get(:s5_proxy_force_cc, "cn")
      cc =
        Enum.reduce(group, %{}, fn v, acc ->
          ip2 =
            case Skn.DB.ProxyIP2.read(v[:ip]) do
              nil ->
                Luminati.Keeper.update(v[:ip], :ok)
                %{info: %{}}

              v1 ->
                v1
            end
          geox = if v[:info][:geo] != nil, do: v[:info][:geo], else: ip2[:info][:geo]
          if s5_proxy_force_cc == nil do
            case geox do
              nil ->
                GeoIP.update(v[:ip], true)
                acc

              geo ->
                cck = String.downcase(geo["country_code"])
                l = :sets.to_list(:sets.add_element(cck, :sets.from_list(Map.get(acc, :list, []))))
                ccm = Map.get(acc, cck, [])
                pl = Enum.sort [v[:id]| ccm]
                acc = Map.put(acc, :list, l)
                Map.put(acc, cck, pl)
            end
          else
            cck = s5_proxy_force_cc
            l = :sets.to_list(:sets.add_element(cck, :sets.from_list(Map.get(acc, :list, []))))
            ccm = Map.get(acc, cck, [])
            pl = Enum.sort [v[:id]| ccm]
            acc = Map.put(acc, :list, l)
            Map.put(acc, cck, pl)
          end
        end)

      {:noreply, %{state | cc: cc}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:update, group}, %{ptr: ptr} = state) do
    group1 = Enum.map(group, fn v -> v[:id] end)
    ptr = if ptr >= length(group1), do: 0, else: ptr
    {:noreply, %{state | group: group1, ptr: ptr}}
  end

  def handle_cast({:remove, proxy}, %{ptr: ptr, group: group0} = state) do
    group = List.delete(group0, proxy[:id])
    ptr = if ptr >= length(group), do: 0, else: ptr
    {:noreply, %{state | group: group, ptr: ptr}}
  end

  def handle_cast(request, state) do
    Logger.warn("drop unknown cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:update_static, state) do
    proxies = Skn.DB.ProxyList.list_tag(:static)
    tm_proxy_sync = Skn.Config.get(:tm_proxy_sync, 1200_000)
    reset_timer(:update_static_ref, :update_static, tm_proxy_sync)
    handle_cast({:update, proxies}, state)
  end

  def handle_info({:update, group}, state) do
    handle_cast({:update, group}, state)
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.debug "stopped by #{inspect reason}"
    :ok
  end
end
