defmodule ProxyGroup do
  @moduledoc """
      Manager a group of proxy, if proxy die, grab new one from database
  """
  use GenServer
  require Logger
  import Skn.Util, only: [
    reset_timer: 3
  ]

  def create_db() do
    case :ets.info(:proxy_group_super) do
      :undefined ->
        :ets.new(:proxy_group_super, [:public, :ordered_set, :named_table, {:read_concurrency, true}, {:write_concurrency, true}])
      _ ->
        :ok
    end
    case :ets.info(:proxy_group_static) do
      :undefined ->
        :ets.new(:proxy_group_static, [:public, :ordered_set, :named_table, {:read_concurrency, true}, {:write_concurrency, true}])
      _ ->
        :ok
    end
  end

  def choose(config, botid, cc, idx \\ 0) do
    proxy = config[:proxy]
    proxy_auth = config[:proxy_auth]

    case proxy do
      {:group, id} ->
        ret = grab_proxy(proxy_to_name({id, nil}), botid, cc, idx)
        Map.merge(ret, %{proxy_auth: new_proxy_session(ret[:proxy_auth], botid, cc)})
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

  def groups() do
    2
  end

  def grab_proxy(group, botid, cc, idx) do
    GenServer.call(group, {:get, botid, cc, idx}, 60000)
  end

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: proxy_to_name({id, nil}))
  end

  def init(id) do
    Process.flag(:trap_exit, true)
    reset_timer(:update_proxy_ref, :update_proxy, 1000)
    {:ok, %{id: id}}
  end

  def handle_call({:get, botid, cc, idx}, _from, %{id: id} = state) do
    r = select_proxy(id2tab(id), cc)
    idx2 = if is_integer(idx), do: idx + 1, else: idx
    proxy = Map.merge(r, %{proxy_auth_fun: {__MODULE__, :choose, [%{proxy: {:group, id}}, botid, cc, idx2]}})
    {:reply, proxy, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast({:update, group}, %{id: id} = state) do
    s5_proxy_force_cc =
      if id == :static do
        Skn.Config.get(:s5_proxy_force_cc, "cn")
      else
        nil
      end
    Enum.each(group, fn x ->
      update_proxy(id2tab(id), x, s5_proxy_force_cc)
    end)
    {:noreply, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop unknown cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:update_proxy, %{id: id} = state) do
    proxies =
      if id == :static do
        Skn.DB.ProxyList.list_tag(:static)
      else
        Skn.DB.ProxyList.list_tag(:super)
      end
    tm_proxy_sync = Skn.Config.get(:tm_proxy_sync, 1200_000)
    reset_timer(:update_proxy_ref, :update_proxy, tm_proxy_sync)
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

  defp update_proxy(tab, %{id: {proxy, proxy_auth}, info: info}, s5_proxy_force_cc) do
    cc = if s5_proxy_force_cc == nil, do: info[:geo]["country_code"], else: s5_proxy_force_cc
    case :ets.match_object(tab, {{:_, proxy}, :_, :_, :_}) do
      [] ->
        :ets.insert(tab, {{0, proxy}, proxy_auth, info[:proxy_remote], cc})
      [{id, _, _, _}|r] ->
        Enum.each r, fn {k, _, _, _} -> :ets.delete(tab, k) end
        :ets.insert(tab, {id, proxy_auth, info[:proxy_remote], cc})
    end
  end

  defp select_proxy(tab, cc) do
    if cc == nil do
      case :ets.first(tab) do
        :'$end_of_table' ->
          %{proxy: nil, proxy_auth: nil, proxy_remote: nil}
        key when is_tuple(key) ->
          case :ets.lookup(tab, key) do
            [] ->
              select_proxy(tab, cc)
            [{{cnt, proxy}, proxy_auth, proxy_remote, proxy_cc}] ->
              :ets.delete(tab, key)
              :ets.insert(tab, {{cnt + 1, proxy}, proxy_auth, proxy_remote, proxy_cc})
              %{proxy: proxy, proxy_auth: proxy_auth, proxy_remote: proxy_remote}
          end
        key ->
          :ets.delete(tab, key)
          select_proxy(tab, cc)
      end
    else
      ms =
        [{
          {:_, :_, :_, :"$1"}, [{:orelse, {:==, :"$1", nil}, {:==, :"$1", cc}}], [:"$_"]
        }]

      case :ets.select(tab, ms, 1) do
        {[{{cnt, proxy}, proxy_auth, proxy_remote, proxy_cc}], _} ->
          :ets.delete(tab, {cnt, proxy})
          :ets.insert(tab, {{cnt + 1, proxy}, proxy_auth, proxy_remote, proxy_cc})
          %{proxy: proxy, proxy_auth: proxy_auth, proxy_remote: proxy_remote}
        _ ->
          %{proxy: nil, proxy_auth: nil, proxy_remote: nil}
      end
    end
  end

  defp id2tab(:static), do: :proxy_group_static
  defp id2tab(_), do: :proxy_group_super

  def update_all() do
    proxies = Skn.DB.ProxyList.list_tag(:super)
    for id <- 1..groups() do
      GenServer.cast(proxy_to_name({id, nil}), {:update, proxies})
    end
  end

  def update_static() do
    proxies = Skn.DB.ProxyList.list_tag(:static)
    GenServer.cast(proxy_to_name({:static, nil}), {:update, proxies})
  end
end
