defmodule Skn.DB.ProxyIP2 do
  require Skn.Proxy.Repo
  @doc """
  More stats info
  total_x => total of counter x
  status:
  account: account/ip/time
  farm: farm/ip/time
  pid:
  nnode:
  geo:
  built:
  pinned:
  updated:
  created:
  reused:
  banned:

  total_account:
  total_task:
  total_built:
  total_updated:
  total_pinned:
  total_reused:
  total_banned:
  """

  def update_geo(ip, keeper, geo, is_staticx \\ false) do
    is_static = (is_staticx == true or is_staticx == :unstable)
    case get(ip) do
      nil ->
        ts_now = System.system_time(:millisecond)
        write(
          ip,
          keeper,
          %{
            status: :ok,
            account: 0,
            farm: 0,
            total_account: 0,
            total_task: 0,
            nnode: nil,
            pid: nil,
            geo: geo,
            static: is_static,
            built: 0,
            updated: 0,
            pinned: 0,
            banned: 0,
            reused: 0,
            created: ts_now,
            total_built: [],
            total_updated: [],
            total_pinned: [],
            total_banned: [],
            total_reused: []
          }
        )
      v ->
        v1 = to_map(v)
        write(ip, keeper, Map.merge(v1[:info], %{geo: geo, static: is_static}))
    end
  end

  def update_status(ip, keeper, status) do
    ts_now = System.system_time(:millisecond)
    case get(ip) do
      nil ->
        banned = if status == :banned, do: ts_now, else: 0
        write(
          ip,
          keeper,
          %{
            status: status,
            account: 0,
            farm: 0,
            total_account: 0,
            total_task: 0,
            nnode: nil,
            pid: nil,
            geo: nil,
            built: 0,
            updated: 0,
            pinned: 0,
            banned: banned,
            reused: 0,
            created: ts_now,
            total_built: [],
            total_updated: [],
            total_pinned: [],
            total_banned: [],
            total_reused: []
          }
        )
        {:new, status}
      v ->
        v1 = to_map(v)
        case {status, v1[:info][:status]} do
          {:ok, :ok} -> :old
          {:banned, :banned} -> :old
          {:banned, :ok} ->
            total_banned = [ts_now | v1[:info][:total_banned]]
            info1 = Map.merge v1[:info], %{status: status, banned: ts_now, total_banned: total_banned}
            write(ip, keeper, info1)
            {:updated, status}
          {:ok, :banned} ->
            total_reused = [ts_now | v1[:info][:total_reused]]
            info1 = Map.merge v1[:info], %{status: status, reused: ts_now, total_reused: total_reused}
            write(ip, keeper, info1)
            {:reused, ts_now - v1[:info][:banned]}
        end
    end
  end

  def write(ip, keeper, info) do
    obj = Skn.Proxy.Repo.proxy_ip2(id: ip, keeper: keeper, info: info)
    :mnesia.dirty_write(:proxy_ip2, obj)
  end

  def update_farm(ip, keeper, pid, incr) do
    ts_now = System.system_time(:millisecond)
    case get(ip) do
      nil ->
        nil
      v ->
        v1 = to_map(v)
        nnode = if is_pid(pid), do: node(pid), else: nil
        {pinned, total_pinned} = if (pid == v1[:pid]) or (pid == nil) do
          {v1[:info][:pinned], v1[:info][:total_pinned]}
        else
          {ts_now, [ts_now | v1[:info][:total_pinned]]}
        end
        {farm, total_task} = if incr == 0 or incr == :keep do
          {v1[:info][:farm], v1[:info][:total_task]}
        else
          {v1[:info][:farm] + 1, v1[:info][:total_task] + 1}
        end
        {updated, total_updated} = if incr == 0 or incr == :keep do
          {v1[:info][:updated], v1[:info][:total_updated]}
        else
          {ts_now, [ts_now | v1[:info][:total_updated]]}
        end
        total_pinned = Enum.slice(total_pinned, 0, 5)
        total_updated = Enum.slice(total_updated, 0, 5)
        info1 = Map.merge(v1[:info],
          %{
            farm: farm,
            total_task: total_task,
            pid: pid,
            nnode: nnode,
            updated: updated,
            total_updated: total_updated,
            pinned: pinned,
            total_pinned: total_pinned
          })
        if info1 != v1[:info] do
          write(ip, keeper, info1)
        end
    end
  end

  def update_account(ip, keeper, incr) do
    case get(ip) do
      nil ->
        nil
      v ->
        v1 = to_map(v)
        if incr == 0 do
          # optimize mnesia write
          :ok
        else
          ts_now = System.system_time(:millisecond)
          account = v1[:info][:account] + incr
          total_built = [ts_now | v1[:info][:total_built]]
          info1 = Map.merge(v1[:info], %{account: account, built: ts_now, total_built: total_built})
          write(ip, keeper, info1)
        end
    end
  end

  def get_by(keeper) do
    :mnesia.dirty_match_object(:proxy_ip2, {:proxy_ip2, :_, keeper, :_})
  end

  def get_all() do
    :mnesia.dirty_match_object(:proxy_ip2, {:proxy_ip2, :_, :_, :_})
  end

  def get_by_status(status0, age \\ 3600_000, farm0 \\ 1) do
    ips = get_all()
    age = if age == :all, do: 0, else: System.system_time(:millisecond) - age
    ips1 = Enum.filter(
      ips,
      fn {:proxy_ip2, _ip, _keeper, info} ->
        ((info[:updated] >= age) or (info[:pinned] >= age) or (info[:banned] >= age) or (info[:reused] >= age) or
         (info[:created] >= age)) and (info[:status] == status0) and (farm0 == :all or info[:farm] == farm0)
      end
    )
    Enum.map(
      ips1,
      fn {:proxy_ip2, ip, keeper, info} ->
        %{ip: ip, keeper: keeper, info: info}
      end
    )
    ips
  end

  def read(ip) do
    case get(ip) do
      nil -> nil
      {:proxy_ip2, ip, keeper, info} ->
        %{ip: ip, keeper: keeper, info: info}
    end
  end

  def get(ip) do
    case :mnesia.dirty_read(:proxy_ip2, ip) do
      [c | _] -> c
      _ -> nil
    end
  end

  def delete(ip) do
    :mnesia.dirty_delete(:proxy_ip2, ip)
  end

  def to_map(c) do
    %{ip: Skn.Proxy.Repo.proxy_ip2(c, :id), keeper: Skn.Proxy.Repo.proxy_ip2(c, :keeper), info: Skn.Proxy.Repo.proxy_ip2(c, :info)}
  end
end