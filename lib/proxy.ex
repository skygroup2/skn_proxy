defmodule Skn.Proxy.Sup do
  def start_proxy_hook() do
    http_port = Skn.Config.get(:web_proxy_port, nil)
    if is_integer(http_port) and http_port > 1024 and http_port < 65535 do
      dispatch = :cowboy_router.compile([{:_, [{:_, Skn.Proxy.RestApi, []}]}])
      :cowboy.start_clear(:http, [{:port, http_port}], %{env: %{dispatch: dispatch}})
    else
      {:ok, :ignore}
    end
  end
end

defmodule Skn.Proxy do
  @country_list [:ae , :af , :ag , :ai , :al , :am , :an , :ao , :aq , :ar , :as , :at , :au , :aw , :ax , :az , :ba , :bb , :bd , :be , :bf , :bg , :bh , :bi , :bj , :bl , :bm , :bn , :bo , :br , :bs , :bt , :bv , :bw , :by , :bz , :ca , :cc , :cd , :cf , :cg , :ch , :ci , :ck , :cl , :cm , :cn , :co , :cr , :cu , :cv , :cx , :cy , :cz , :de , :dj , :dk , :dm , :do , :dz , :ec , :ee , :eg , :eh , :er , :es , :et , :fi , :fj , :fk , :fm , :fo , :fr , :ga , :gb , :gd , :ge , :gf , :gg , :gh , :gi , :gl , :gm , :gn , :gp , :gq , :gr , :gs , :gt , :gu , :gw , :gy , :hk , :hm , :hn , :hr , :ht , :hu , :id , :ie , :il , :im , :in , :io , :iq , :ir , :is , :it , :je , :jm , :jo , :jp , :ke , :kg , :kh , :ki , :km , :kn , :kp , :kr , :kw , :ky , :kz , :la , :lb , :lc , :li , :lk , :lr , :ls , :lt , :lu , :lv , :ly , :ma , :mc , :md , :me , :mf , :mg , :mh , :mk , :ml , :mm , :mn , :mo , :mp , :mq , :mr , :ms , :mt , :mu , :mv , :mw , :mx , :my , :mz , :na , :nc , :ne , :nf , :ng , :ni , :nl , :no , :np , :nr , :nu , :nz , :om , :pa , :pe , :pf , :pg , :ph , :pk , :pl , :pm , :pn , :pr , :ps , :pt , :pw , :py , :qa , :re , :ro , :rs , :ru , :rw , :sa , :sb , :sc , :sd , :se , :sg , :sh , :si , :sj , :sk , :sl , :sm , :sn , :so , :sr , :ss , :st , :sv , :sy , :sz , :tc , :td , :tf , :tg , :th , :tj , :tk , :tl , :tm , :tn , :to , :tr , :tt , :tv , :tw , :tz , :ua , :ug , :um , :us , :uy , :uz , :va , :vc , :ve , :vg , :vi , :vn , :vu , :wf , :ws , :ye , :yt , :za , :zm , :zw]
  @country_black_list ["ai" , "an" , "ao" , "aq" , "as" , "bl" , "bv" , "cc" , "cf" , "cg" , "ck" , "cu" , "cx" , "dj" , "eh" , "er" , "fk" , "gs" , "gw" , "hm" , "io" , "ki" , "km" , "kp" , "kr" , "kz" , "li" , "ls" , "mf" , "mh" , "ms" , "mw" , "nf" , "nr" , "nu" , "pn" , "pw" , "sb" , "sc" , "sh" , "sj" , "sl" , "sm" , "ss" , "td" , "tf" , "tk" , "tl" , "to" , "tv" , "um" , "va" , "vg" , "vu" , "wf" , "ye" , "xk" , "cn" , "ru" , "tw" , "hk" , "il" , "dz" , "eg" , "id" , "in" , "ir" , "ma" , "pk" , "ps" , "sy" , "th" , "uy" , "tn" , "sa" , "sn" , "bi" , "st" , "gn" , "pg" , "ws" , "ne" , "mp" , "sz" , "lc" , "fm" , "rw" , "bf" , "cd" , "tm" , "lr" , "mr" , "cm" , "et" , "yt" , "az" , "so" , "pm" , "tg" , "vn" , "my" , "ua" , "tr" , "ec" , "do" , "om" , "vi" , "sx" , "kh" , "dm" , "ag" , "bt" , "mc" , "af" , "cv" , "gq" , "bw" , "bd" , "ga" , "gm" , "ml"]


  def country_list() do
    @country_list
  end

  def country_black_list() do
    @country_black_list
  end

  def force_country_black_list() do
    default = []
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
          %{info: %{status: status, geo: %{"country" => cc}}} when byte_size(cc) == 2 ->
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
    a = :rpc.call(Skn.Config.get(:master), Skn.Config, :get, [:proxy_ip_country_list])
    update_country_percent(a)
  end
end