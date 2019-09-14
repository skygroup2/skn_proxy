defmodule Skn.DB.ProxyList do
  use Bitwise
  require Skn.Proxy.Repo
  require Logger

  def to_file(file, tag \\ nil) do
    keys = :mnesia.dirty_all_keys(:proxy_status)
    data = Enum.map keys, fn x -> get(x) end
    data = if tag != nil do
      Enum.filter data, fn x -> x[:tag] == tag end
    else
      data
    end
    Skn.Util.write_term_db(file, data)
  end

  def from_file(file) do
    {:ok, data} = :file.consult file
    Enum.each data, fn x -> write(x) end
  end

  def sync_super(dnode) do
    if node() == Skn.Config.get(:master) do
      mh = {:proxy_status, :"$1", :"$2", :"$3", :_, :"$4"}
      mg = [{:==, :"$3", :super}]
      mr = {{:"$1", :"$2", :"$4"}}
      ips = :mnesia.dirty_select(:proxy_status, [{mh, mg, [mr]}])
      Enum.each ips, fn ({id, ip, info}) ->
        Command.Gate.async_dist_rpc(dnode, {:proxy_assign, %{id: id, ip: ip, tag: :super, info: info}})
      end
      Command.Gate.async_dist_rpc(dnode, {:proxy_update, :all})
    end
  end

  def sync_static(dnode) do
    if (node() == Skn.Config.get(:master)) do
      mh = {:proxy_status, :"$1", :"$2", :"$3", :"$4", :"$5"}
      mg = [{:==, :"$3", :static}]
      mr = {{:"$1", :"$2", :"$4", :"$5"}}
      ips = :mnesia.dirty_select(:proxy_status, [{mh, mg, [mr]}])
      Enum.each ips, fn {id, ip, assign, info} ->
        failed = Map.get(info, :failed, 0)
        if failed == 0 do
          Command.Gate.async_dist_rpc(dnode, {:proxy_assign, %{id: id, ip: ip, tag: :static, assign: assign, info: info}})
        end
      end
      Command.Gate.async_dist_rpc(dnode, {:proxy_update, :static})
    end
  end

  def sync_static() do
    if (node() == Skn.Config.get(:master)) do
      nodes = Skn.Config.get(:slaves, [])
      Enum.each nodes, fn x ->
        sync_static(x)
      end
    end
  end

  def get(id) do
    case :mnesia.dirty_read(:proxy_status, id) do
      [c | _] ->
        %{
          id: Skn.Proxy.Repo.proxy_status(c, :id),
          ip: Skn.Proxy.Repo.proxy_status(c, :ip),
          tag: Skn.Proxy.Repo.proxy_status(c, :tag),
          info: Skn.Proxy.Repo.proxy_status(c, :info),
          assign: Skn.Proxy.Repo.proxy_status(c, :assign)
        }
      _ ->
        nil
    end
  end

  def get_ip(ip) do
    cx = :mnesia.dirty_match_object(:proxy_status, {:proxy_status, :_, ip, :_, :_, :_})
    Enum.map cx, fn c ->
      %{
        id: Skn.Proxy.Repo.proxy_status(c, :id),
        ip: Skn.Proxy.Repo.proxy_status(c, :ip),
        tag: Skn.Proxy.Repo.proxy_status(c, :tag),
        info: Skn.Proxy.Repo.proxy_status(c, :info),
        assign: Skn.Proxy.Repo.proxy_status(c, :assign)
      }
    end
  end

  def update_geo(ip, geo) do
    proxies = get_ip(ip)
    proxies = Enum.map proxies, fn x ->
      info = Map.get x, :info, %{}
      info = Map.put info, :geo, geo
      Map.put x, :info, info
    end
    Enum.each proxies, fn x -> write(x) end
  end

  def write(proxy) do
    id = proxy[:id]
    ip = proxy[:ip]
    tag = proxy[:tag]
    assign = proxy[:assign]
    ts_now = :erlang.system_time(:millisecond)
    info = Map.get(proxy, :info, %{updated: ts_now})
    obj = Skn.Proxy.Repo.proxy_status(id: id, ip: ip, tag: tag, info: info, assign: assign)
    :mnesia.dirty_write(:proxy_status, obj)
  end

  def update(proxy) do
    id = proxy[:id]
    ip = proxy[:ip]
    tag = proxy[:tag]
    assign = proxy[:assign]
    info = case get(id) do
      %{info: i} ->
        used = Map.get(i, :used, 0)
        Map.merge(%{used: used}, Map.get(proxy, :info, %{}))
      _ ->
        Map.get(proxy, :info, %{})
    end
    obj = Skn.Proxy.Repo.proxy_status(id: id, ip: ip, tag: tag, info: info, assign: assign)
    :mnesia.dirty_write(:proxy_status, obj)
  end

  def update_failed(proxy) do
    update_counter(proxy, :failed)
  end

  def update_used(proxy) do
    update_counter(proxy, :used)
  end

  def set_info(proxy, field, value) do
    case get(proxy[:id]) do
      %{info: info} = c ->
        ts_now = :erlang.system_time(:millisecond)
        info = Map.merge(info, %{field => value, :updated => ts_now})
        c1 = Map.put c, :info, info
        write(c1)
      _ ->
        :ignore
    end
  end

  def get_info(proxy, field, default) do
    case get(proxy[:id]) do
      %{info: info} ->
        Map.get(info, field, default)
      _ ->
        default
    end
  end

  def update_counter(proxy, name) do
    proxy_id = proxy[:id]
    incr = proxy[:incr]
    ip = proxy[:ip]
    tag = proxy[:tag]
    ts_now = :erlang.system_time(:millisecond)
    case get(proxy_id) do
      nil when ip != nil and tag != nil ->
        failed = if incr > 0, do: incr, else: 0
        info = Map.get proxy, :info, %{}
        info = Map.merge info, %{name => failed, :updated => ts_now}
        c = %{id: proxy_id, ip: ip, tag: tag, info: info}
        write(c)
      nil ->
        :ignore
      c ->
        failed = Map.get(c[:info], name, 0) + incr
        failed = if failed > 0 and incr != 0, do: failed, else: 0
        info1 = Map.merge c[:info], %{name => failed, :updated => ts_now}
        c = Map.put c, :info, info1
        write(c)
    end
  end

  def replace_lum(account, zone, password) do
    ips = Skn.DB.ProxyList.list_tag(:super)
    Enum.each ips, fn x ->
      case Skn.DB.ProxyList.get(x[:id]) do
        c when is_map(c) ->
          {proxy, _} = x[:id]
          id1 = {proxy, {:lum, "lum-customer-#{account}-zone-#{zone}", password}}
          c1 = Map.put c, :id, id1
          Skn.DB.ProxyList.delete(x[:id])
          Skn.DB.ProxyList.write(c1)
        _ ->
          :ignore
      end
    end
  end

  def delete_by_assign(assign) do
    if assign != nil do
      cx = :mnesia.dirty_match_object(:proxy_status, {:proxy_status, :_, :_, :_, assign, :_})
      Enum.each cx, fn c ->
        id = Skn.Proxy.Repo.proxy_status(c, :id)
        :mnesia.dirty_delete(:proxy_status, id)
      end
      Enum.reduce(cx, [], fn c, acc ->
        id = Skn.Proxy.Repo.proxy_status(c, :id)
        case id do
          {proxy, _} ->
            [proxy| acc]
          true ->
            acc
        end
      end)
    else
      []
    end
  end

  def delete(id) do
    :mnesia.dirty_delete(:proxy_status, id)
  end

  def list_tag_by_failed(tag \\ :static, failed \\ 0) do
    mh = {:proxy_status, :"$1", :"$2", :"$3", :"$4", :"$5"}
    mg = [{:==, :"$3", tag}]
    mr = {{:"$1", :"$2", :"$4", :"$5"}}
    ips = :mnesia.dirty_select(:proxy_status, [{mh, mg, [mr]}])
    ips = Enum.map ips, fn {id, ip, assign, info} -> %{id: id, ip: ip, tag: tag, assign: assign, info: info} end
    Enum.filter ips, fn x ->
      Map.get(x[:info], :failed, 0) > failed
    end
  end

  def list_all_tag(tag) do
    mh = {:proxy_status, :"$1", :"$2", :"$3", :"$4", :"$5"}
    mg = [{:==, :"$3", tag}]
    mr = {{:"$1", :"$2", :"$4", :"$5"}}
    ips = :mnesia.dirty_select(:proxy_status, [{mh, mg, [mr]}])
    Enum.map ips, fn {id, ip, assign, info} -> %{id: id, ip: ip, tag: tag, assign: assign, info: info} end
  end

  def list_status_tag(tag, status \\ :banned, zone \\ :all) do
    all = list_all_tag(tag)
    Enum.filter all, fn x ->
      (x[:info][:status] == status) and (zone == :all or x[:info][:zone] == zone)
    end
  end

  def list_tag(tag, assign \\ nil, limit \\ 0) do
    mh = {:proxy_status, :"$1", :"$2", :"$3", :"$4", :"$5"}
    mg = cond do
      tag == nil and assign == nil ->
        []
      tag != nil and assign != nil ->
        [{:andalso, {:==, :"$3", tag}, {:==, :"$4", assign}}]
      tag != nil ->
        [{:==, :"$3", tag}]
      true ->
        [{:==, :"$4", assign}]
    end
    mr = {{:"$1", :"$2", :"$4", :"$5"}}
    ips = :mnesia.dirty_select(:proxy_status, [{mh, mg, [mr]}])
    Enum.reduce ips, [], fn ({id, ip, a, info}, acc) ->
      if is_map(info) and Map.get(info, :failed, 0) <= limit do
        [%{id: id, ip: ip, info: info, tag: tag, assign: a} | acc]
      else
        acc
      end
    end
  end

  def list_tag_zone(tag, zone) do
    ips = list_all_tag(tag)
    Enum.filter ips, fn x ->
      case x do
        %{info: %{ zone: z}} ->
          z == zone
        _ ->
          false
      end
    end
  end
end