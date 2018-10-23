defmodule Skn.DB.ProxyList do
  use Bitwise
  require Skn.Proxy.Repo
  require Logger

  def to_file(file, tag \\ nil) do
    keys = :mnesia.dirty_all_keys(:proxy_blocked)
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
      mh = {:proxy_blocked, :"$1", :"$2", :"$3", :_, :"$4"}
      mg = [{:==, :"$3", :super}]
      mr = {{:"$1", :"$2", :"$4"}}
      ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
      Enum.each ips, fn ({id, ip, info}) ->
        Command.Gate.async_dist_rpc(dnode, {:proxy_assign, %{id: id, ip: ip, tag: :super, info: info}})
      end
      Command.Gate.async_dist_rpc(dnode, {:proxy_update, :all})
    end
  end

  def sync_static(dnode) do
    if (node() == Skn.Config.get(:master)) do
      mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
      mg = [{:==, :"$3", :static}]
      mr = {{:"$1", :"$2", :"$4", :"$5"}}
      ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
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
    case :mnesia.dirty_read(:proxy_blocked, id) do
      [c | _] ->
        %{
          id: Skn.Proxy.Repo.proxy_blocked(c, :id),
          ip: Skn.Proxy.Repo.proxy_blocked(c, :ip),
          tag: Skn.Proxy.Repo.proxy_blocked(c, :tag),
          info: Skn.Proxy.Repo.proxy_blocked(c, :info),
          assign: Skn.Proxy.Repo.proxy_blocked(c, :assign)
        }
      _ ->
        nil
    end
  end

  def get_ip(ip) do
    cx = :mnesia.dirty_match_object(:proxy_blocked, {:proxy_blocked, :_, ip, :_, :_, :_})
    Enum.map cx, fn c ->
      %{
        id: Skn.Proxy.Repo.proxy_blocked(c, :id),
        ip: Skn.Proxy.Repo.proxy_blocked(c, :ip),
        tag: Skn.Proxy.Repo.proxy_blocked(c, :tag),
        info: Skn.Proxy.Repo.proxy_blocked(c, :info),
        assign: Skn.Proxy.Repo.proxy_blocked(c, :assign)
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
    obj = Skn.Proxy.Repo.proxy_blocked(id: id, ip: ip, tag: tag, info: info, assign: assign)
    :mnesia.dirty_write(:proxy_blocked, obj)
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
    obj = Skn.Proxy.Repo.proxy_blocked(id: id, ip: ip, tag: tag, info: info, assign: assign)
    :mnesia.dirty_write(:proxy_blocked, obj)
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
          id1 = {proxy, {:sessioner, "lum-customer-#{account}-zone-#{zone}", password}}
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
      cx = :mnesia.dirty_match_object(:proxy_blocked, {:proxy_blocked, :_, :_, :_, assign, :_})
      Enum.each cx, fn c ->
        id = Skn.Proxy.Repo.proxy_blocked(c, :id)
        :mnesia.dirty_delete(:proxy_blocked, id)
      end
      Enum.reduce(cx, [], fn c, acc ->
        id = Skn.Proxy.Repo.proxy_blocked(c, :id)
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
    :mnesia.dirty_delete(:proxy_blocked, id)
  end

  def ensure_geo(%{ip: ip, info: info} = p) do
    case info do
      %{geo: geo} when is_map(geo) ->
        geo["country_code"]
      %{failed: 0} ->
        case Skn.Proxy.SqlApi.get_GeoIP(ip) do
        %{geo: geo} when is_map(geo) ->
            update_geo(ip, GeoIP.compress_geo(geo))
            geo["country_code"]
        _ ->
            GeoIP.update(p, true)
            nil
        end
      _ ->
        nil
    end
  end

  def list_tag_by_cc(tag, assign, cc) do
    mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
    mg = [{:andalso, {:==, :"$3", tag}, {:==, :"$4", assign}}]
    mr = {{:"$1", :"$2", :"$5"}}
    ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
    Enum.reduce ips, [], fn ({id, ip, info}, acc) ->
      failed = Map.get(info, :failed, 0)
      case info do
        _ when cc == nil ->
          [%{id: id, ip: ip, info: info, tag: tag, assign: assign} | acc]
        %{geo: geo} when is_map(geo) and failed == 0 ->
          if String.downcase(geo["country_code"]) == cc do
            [%{id: id, ip: ip, info: info, tag: tag, assign: assign} | acc]
          else
            acc
          end
        _ ->
          acc
      end
    end
  end

  def list_tag_by_failed(tag \\ :static, failed \\ 0) do
    mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
    mg = [{:==, :"$3", tag}]
    mr = {{:"$1", :"$2", :"$4", :"$5"}}
    ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
    ips = Enum.map ips, fn {id, ip, assign, info} -> %{id: id, ip: ip, tag: tag, assign: assign, info: info} end
    Enum.filter ips, fn x ->
      ensure_geo(x) == nil or Map.get(x[:info], :failed, 0) > failed
    end
  end

  def assign_fm(tag \\ :static) do
    if node() == Skn.Config.get(:master) do
      mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
      mg = [{:andalso, {:==, :"$3", tag}, {:==, :"$4", nil}}]
      mr = {{:"$1", :"$2", :"$5"}}
      ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
      ips = Enum.filter ips, fn {_, ip, info} ->
        failed = Map.get info, :failed, 0
        case Skn.DB.ProxyIP2.read(ip) do
          %{
            info: %{
              status: :ok
            }
          } when failed == 0 -> true
          _ -> false
        end
      end
      ips = Enum.filter ips, fn {id, ip, info} ->
        ensure_geo(%{id: id, ip: ip, tag: tag, info: info}) != nil and Map.get(info, :failed, 0) == 0
      end
      nodes = Enum.sort Skn.Config.get(:slaves, [])
      num_node = length(nodes)
      if num_node > 0 do
        Enum.each ips, fn {id, ip, info} ->
          h = :erlang.phash2(ip)
          i = rem(h, num_node)
          write(%{id: id, ip: ip, tag: tag, assign: Enum.at(nodes, i), info: info})
        end
      end
    end
  end

  def assign_search(count, max_search \\ 25, is_socks \\ false) do
    if node() == Skn.Config.get(:master) do
      mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
      mg = [
        {
          :andalso,
          {:==, :"$3", :static},
          {:orelse, {:==, :"$4", nil}, {:==, :"$4", :search}}
        }
      ]
      mr = {{:"$1", :"$2", :"$4", :"$5"}}
      ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
      ips_ok = Enum.filter ips, fn {id, _, _, info} ->
        is_ok = Map.get(info, :failed, 1) == 0
        case id do
          {{:socks5, _, _}, _} ->
            is_socks
          _ ->
            is_ok
        end
      end
      ips0 = Enum.filter ips, fn {_, _, assign, info} ->
        case info do
          %{search_id: search_id, failed: failed} when assign == :search and search_id != nil and failed == 0 ->
            true
          _ ->
            false
        end
      end
      if length(ips0) < count do
        ipsx = ips0 ++ Enum.slice((ips_ok -- ips0), 0, count - length(ips0))
        Enum.reduce ipsx, 1, fn ({id, ip, _, info}, acc) ->
          search_id = Map.get(info, :search_id, 0)
          failed = Map.get(info, :failed, 1)
          if failed == 0 and search_id == 0 or search_id == nil do
            search_id1 = rem(acc, max_search)
            search_id1 = if search_id1 == 0, do: max_search, else: search_id1
            info1 = Map.put(info, :search_id, search_id1)
            v1 = %{id: id, ip: ip, tag: :static, assign: :search, info: info1}
            Skn.DB.ProxyList.write(v1)
          end
          acc + 1
        end
      end
    end
  end

  def assign_ah(count, zone \\ ["s5"]) do
    if node() == Skn.Config.get(:master) do
      mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
      mg = [
        {
          :andalso,
          {:==, :"$3", :static},
          {:orelse, {:==, :"$4", nil}, {:==, :"$4", :ah}}
        }
      ]
      mr = {{:"$1", :"$2", :"$5"}}
      ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
      {ah, avail, banned} = Enum.reduce ips, {[], [], []}, fn ({id, ip, info}, {m, a, b}) ->
        case Skn.DB.ProxyIP2.read(ip) do
          %{
            info: %{
              status: :banned
            }
          } ->
            {m, a, [{id, ip, info} | b]}
          _ ->
            case info do
              %{zone: z} ->
                if z in zone do
                  {m, [{id, ip, info} | a], b}
                else
                  {m, a, b}
                end
              _ ->
                {m, a, b}
            end
        end
      end
      Logger.debug "AH: #{length(ah)}, available: #{length(avail)}, banned: #{length(banned)}"
      if length(ah) >= count do
        thin = Enum.slice ah, count, (length(ah) - count)
        Enum.each thin, fn {id, ip, info} ->
          write(%{id: id, ip: ip, tag: :static, assign: nil, info: info})
        end
      else
        more = Enum.slice(avail, 0, count - length(ah))
        Logger.debug "assigned #{length(more)} proxy to AH"
        Enum.each more, fn {id, ip, info} ->
          write(%{id: id, ip: ip, tag: :static, assign: :ah, info: info})
        end
      end
    end
  end

  def list_tag_zone(tag, zone) do
    ips = list_all_tag(tag)
    Enum.filter ips, fn x ->
      case x do
        %{
          info: %{
            zone: z
          }
        } ->
          z == zone
        _ ->
          false
      end
    end
  end

  def list_all_tag(tag) do
    mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
    mg = [{:==, :"$3", tag}]
    mr = {{:"$1", :"$2", :"$4", :"$5"}}
    ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
    Enum.map ips, fn {id, ip, assign, info} -> %{id: id, ip: ip, tag: tag, assign: assign, info: info} end
  end

  def list_status_tag(tag, status \\ :banned, zone \\ :all) do
    all = list_all_tag(tag)
    Enum.filter all, fn x ->
      (x[:info][:status] == status) and (zone == :all or x[:info][:zone] == zone)
    end
  end

  def list_tag_search() do
    list_tag(:static, :search)
  end

  def list_tag(tag, assign \\ nil, limit \\ 0) do
    mh = {:proxy_blocked, :"$1", :"$2", :"$3", :"$4", :"$5"}
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
    ips = :mnesia.dirty_select(:proxy_blocked, [{mh, mg, [mr]}])
    Enum.reduce ips, [], fn ({id, ip, a, info}, acc) ->
      if is_map(info) and Map.get(info, :failed, 0) <= limit do
        [%{id: id, ip: ip, info: info, tag: tag, assign: a} | acc]
      else
        acc
      end
    end
  end

  def import_s5(prefix, range, port, user, pass) do
    Enum.each range, fn x ->
      ipstr = "#{prefix}.#{x}"
      {:ok, ip} = :inet.parse_address(:erlang.binary_to_list(ipstr))
      p = %{
        id: {{:socks5, ip, port}, {user, pass}},
        ip: ipstr,
        tag: :static,
        assign: nil,
        info: %{
          zone: "s5",
          failed: 1
        }
      }
      write(p)
    end
  end
end