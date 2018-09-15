defmodule ProxyGroup do
  @moduledoc """
      Manager a group of proxy, if proxy die, grab new one from database
  """
  use GenServer
  require Logger
  import Skn.Util, only: [
    reset_timer: 3
  ]

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

  def bot_country(id, _cc) do
    default_cc = ["us", "ca", "gb"]
    Enum.at(default_cc, rem(id, 3))
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

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.debug "stopped by #{inspect reason}"
    :ok
  end
end
