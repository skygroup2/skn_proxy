defmodule Proxy.Keeper do
  @moduledoc """
      count ip address and reused rate
  """
  use GenServer
  require Logger

  import Skn.Util,
    only: [
      reset_timer: 3
    ]

  import Command.Queue,
    only: [
      q_name: 1
    ]

  def size() do
    32
  end

  def reset_proxy_ip() do
    ips = :mnesia.dirty_all_keys(:proxy_ip2)
    ts_now = :erlang.system_time(:millisecond)
    ban_reset = Skn.Config.get(:luminati_ban_reset, 120 * 3600_000)
    week_reset = Skn.Config.get(:luminati_week_reset, 5 * 3600_000)
    account_reset = Skn.Config.get(:luminati_account_reset, 120 * 3600_000)
    delete_old = Skn.Config.get(:luminati_delete_old, false)
    delete_age = Skn.Config.get(:luminati_delete_age, 5 * 24 * 3600_000)
    delete_age2 = Skn.Config.get(:luminati_delete_age2, 15 * 24 * 3600_000)

    Enum.each(ips, fn x ->
      {:proxy_ip2, ip, _keeper, info} = Skn.DB.ProxyIP2.get(x)

      no_delete =
        delete_old == false or (info[:static] != true and ts_now - info[:updated] < delete_age) or
          (info[:static] == true and ts_now - info[:updated] < delete_age2)

      if is_binary(ip) and byte_size(ip) <= 15 and no_delete == true do
        keeper1 = rem(:erlang.phash2(ip), size())
        week1 = if ts_now - info[:updated] > week_reset, do: 0, else: info[:week]
        status1 = if ts_now - info[:banned] > ban_reset, do: :ok, else: info[:status]
        account1 = if ts_now - info[:built] > account_reset, do: 0, else: info[:account]
        {pid1, nnode1} = {nil, nil}

        info1 =
          Map.merge(info, %{
            week: week1,
            status: status1,
            account: account1,
            pid: pid1,
            nnode: nnode1
          })

        if info != info1 do
          Skn.DB.ProxyIP2.write(ip, keeper1, info1)
        end
      else
        Skn.DB.ProxyIP2.delete(ip)
      end
    end)
  end

  def update_geoip(ip, geo, static) do
    keeper = rem(:erlang.phash2(ip), size())
    send(name(keeper), {:update_geo, ip, keeper, geo, static})
  end

  def check_update_geoip(requester, ip, keeper) do
    GeoIP.update({requester, ip, keeper}, false)
  end

  def name(id) do
    id = rem(id, size())
    :erlang.list_to_atom('proxy_keeper_#{id}')
  end

  def update(ip, status) when is_binary(ip) and byte_size(ip) > 0 do
    id = :erlang.phash2(ip)
    master = Skn.Config.get(:master, :farmer1@erlnode1)
    reply_to = :erlang.atom_to_binary(node(), :latin1)
    send_to = :erlang.atom_to_binary(master, :latin1)
    opt = [reply_to: reply_to, correlation_id: "LUM.KEEPER.LOCAL", message_id: my_rk(id)]
    Command.Queue.publish(q_name(:q_dist_router), {:update, ip, status}, send_to, opt)
  end

  def update(_ip, _status) do
    :ok
  end

  def release(from, tid, ips) do
    id = :erlang.phash2(Enum.at(ips, 0))
    master = Skn.Config.get(:master, :farmer1@erlnode1)
    reply_to = :erlang.atom_to_binary(node(), :latin1)
    send_to = :erlang.atom_to_binary(master, :latin1)
    opt = [reply_to: reply_to, correlation_id: "LUM.KEEPER.LOCAL", message_id: my_rk(id)]
    Command.Queue.publish(q_name(:q_dist_router), {:release, from, tid, ips}, send_to, opt)
  end

  def check(from, ip, status \\ :ok) do
    id = :erlang.phash2(ip)
    master = Skn.Config.get(:master, :farmer1@erlnode1)
    reply_to = :erlang.atom_to_binary(node(), :latin1)
    send_to = :erlang.atom_to_binary(master, :latin1)
    opt = [reply_to: reply_to, correlation_id: "LUM.KEEPER.LOCAL", message_id: my_rk(id)]
    Command.Queue.publish(q_name(:q_dist_router), {:check, from, ip, status}, send_to, opt)
  end

  def check2(from, ip, status \\ :ok) do
    id = :erlang.phash2(ip)
    master = Skn.Config.get(:master, :farmer1@erlnode1)
    reply_to = :erlang.atom_to_binary(node(), :latin1)
    send_to = :erlang.atom_to_binary(master, :latin1)
    opt = [reply_to: reply_to, correlation_id: "LUM.KEEPER.LOCAL", message_id: my_rk(id)]
    Command.Queue.publish(q_name(:q_dist_router), {:check2, from, ip, status}, send_to, opt)
  end

  def week_done(from, ip) do
    id = :erlang.phash2(ip)
    master = Skn.Config.get(:master, :farmer1@erlnode1)
    reply_to = :erlang.atom_to_binary(node(), :latin1)
    send_to = :erlang.atom_to_binary(master, :latin1)
    opt = [reply_to: reply_to, correlation_id: "LUM.KEEPER.LOCAL", message_id: my_rk(id)]
    Command.Queue.publish(q_name(:q_dist_router), {:week_done, from, ip}, send_to, opt)
  end

  def rpc_reply(h, from, msg) do
    rk = h[:reply_to]
    message_id = h[:correlation_id]
    opt = [message_id: message_id]
    Command.Queue.publish(q_name(:q_dist_router), {:proxy_keeper_reply, from, msg}, rk, opt)
  end

  def my_rk(id) do
    ixx = rem(id, Proxy.Keeper.size())
    "LUM.KEEPER.#{ixx}"
  end

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: name(id))
  end

  def init(id) do
    rand = id * 10_000
    reset_timer(:schedule_ref, :schedule, 600_000 + rand)
    Command.Router.set(my_rk(id), self())
    {:ok, %{id: id, rk: my_rk(id)}}
  end

  def handle_call(request, from, state) do
    Logger.warn("drop unknown call #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, :badcall}, state}
  end

  def handle_cast(request, state) do
    Logger.warn("drop unknown cast #{inspect(request)}")
    {:noreply, state}
  end

  def handle_info(:schedule, %{id: id} = state) do
    ips = Skn.DB.ProxyIP2.get_by(id)
    ts_now = :erlang.system_time(:millisecond)
    ban_reset = Skn.Config.get(:luminati_ban_reset, 120 * 3600_000)
    week_reset = Skn.Config.get(:luminati_week_reset, 5 * 3600_000)
    pin_reset = Skn.Config.get(:luminati_pin_reset, 1 * 3600_000)
    account_reset = Skn.Config.get(:luminati_account_reset, 120 * 3600_000)
    delete_old = Skn.Config.get(:luminati_delete_old, false)
    delete_age = Skn.Config.get(:luminati_delete_age, 7 * 24 * 3600_000)
    delete_age2 = Skn.Config.get(:luminati_delete_age2, 15 * 24 * 3600_000)

    Enum.each(ips, fn {:proxy_ip2, ip, keeper, info} ->
      no_delete =
        delete_old == false or (info[:static] != true and ts_now - info[:updated] < delete_age) or
          (info[:static] == true and ts_now - info[:updated] < delete_age2)

      if no_delete == true do
        week1 = if ts_now - info[:updated] > week_reset, do: 0, else: info[:week]
        status1 = if ts_now - info[:banned] > ban_reset, do: :ok, else: info[:status]

        {pid1, nnode1} =
          if ts_now - info[:pinned] > pin_reset, do: {nil, nil}, else: {info[:pid], info[:nnode]}

        account1 = if ts_now - info[:built] > account_reset, do: 0, else: info[:account]

        info1 =
          Map.merge(info, %{
            week: week1,
            account: account1,
            status: status1,
            pid: pid1,
            nnode: nnode1
          })

        if info != info1 do
          Skn.DB.ProxyIP2.write(ip, keeper, info1)
        end
      else
        Skn.DB.ProxyIP2.delete(ip)
      end
    end)

    reset_timer(:schedule_ref, :schedule, 1500_000)
    {:noreply, state}
  end

  def handle_info({:rpc, h, {:check2, from, ip, status}}, %{id: id} = state) do
    ts_now = :erlang.system_time(:millisecond)

    case Skn.DB.ProxyIP2.get(ip) do
      nil ->
        check_update_geoip(self(), ip, id)

        info = %{
          status: :ok,
          account: 1,
          week: 0,
          total_account: 1,
          total_week: 0,
          nnode: nil,
          pid: nil,
          geo: nil,
          built: ts_now,
          updated: 0,
          pinned: 0,
          banned: 0,
          reused: 0,
          created: ts_now,
          total_built: [ts_now],
          total_updated: [],
          total_pinned: [],
          total_banned: [],
          total_reused: []
        }

        Skn.DB.ProxyIP2.write(ip, id, info)
        Skn.Counter.update_counter(:proxy_ip_new, 1)
        rpc_reply(h, from, {:check2_ack, ip})

      v ->
        v1 = Skn.DB.ProxyIP2.to_map(v)

        if v1[:info][:geo] == nil do
          check_update_geoip(self(), ip, id)
        end

        case {v1[:info][:status], status} do
          {:banned, :ok} ->
            time = ts_now - v1[:info][:banned]
            c = Skn.Counter.update_counter(:proxy_reuse_count, 1)
            Skn.Counter.update_counter(:proxy_ip_reused, 1)
            ravg = Skn.Counter.read(:proxy_reuse_avg)
            rmin = Skn.Counter.read(:proxy_reuse_min)
            rmax = Skn.Counter.read(:proxy_reuse_max)
            rmin1 = if rmin == 0, do: time, else: min(time, rmin)
            rmax1 = max(time, rmax)
            ravg1 = trunc((ravg * (c - 1) + time) / c)
            Skn.Counter.write(:proxy_reuse_avg, ravg1)
            Skn.Counter.write(:proxy_reuse_min, rmin1)
            Skn.Counter.write(:proxy_reuse_max, rmax1)

          _ ->
            Skn.Counter.update_counter(:proxy_ip_old, 1)
        end

        built_age = ts_now - v1[:info][:built]
        account_reset = Skn.Config.get(:luminati_account_reset, 120 * 3600_000)
        def_account_max = Skn.Config.get(:luminati_account_per_ip, 45)
        geo = Map.get(v1[:info], :geo, %{"country_code" => "VN"})
        cc = if is_map(geo), do: geo["country_code"], else: "VN"
        geo_account_max = Skn.Config.get({:luminati_account_per_ip, cc}, def_account_max)
        strict_ip = Skn.Config.get(:luminati_strict_ip, true)
        is_ok = status == :ok or v1[:info][:status] == :ok

        cond do
          strict_ip == false ->
            Skn.DB.ProxyIP2.update_account(ip, id, v1[:info][:account] + 1)
            rpc_reply(h, from, {:check2_ack, ip})

          is_ok == true and v1[:info][:account] < geo_account_max ->
            Skn.DB.ProxyIP2.update_account(ip, id, v1[:info][:account] + 1)
            rpc_reply(h, from, {:check2_ack, ip})

          is_ok == true and built_age > account_reset ->
            Skn.DB.ProxyIP2.update_account(ip, id, 1)
            rpc_reply(h, from, {:check2_ack, ip})

          true ->
            rpc_reply(h, from, {:check2_error, ip, v1[:info][:status], v1[:info][:account]})
        end

        #            rpc_reply(h, {:check2_ack, from, ip})
    end

    {:noreply, state}
  end

  def handle_info({:rpc, h, {:check, from, ip, status}}, %{id: id} = state) do
    ts_now = :erlang.system_time(:millisecond)

    case Skn.DB.ProxyIP2.get(ip) do
      nil ->
        check_update_geoip(self(), ip, id)
        nname = if is_pid(from), do: node(from), else: nil

        info = %{
          status: :ok,
          account: 0,
          week: 0,
          total_account: 0,
          total_week: 0,
          nnode: nname,
          pid: from,
          geo: nil,
          built: 0,
          updated: 0,
          pinned: ts_now,
          banned: 0,
          reused: 0,
          created: ts_now,
          total_built: [],
          total_updated: [],
          total_pinned: [ts_now],
          total_banned: [],
          total_reused: []
        }

        Skn.DB.ProxyIP2.write(ip, id, info)
        Skn.Counter.update_counter(:proxy_ip_new, 1)
        rpc_reply(h, from, {:check_ack, ip})

      v ->
        v1 = Skn.DB.ProxyIP2.to_map(v)

        if v1[:info][:geo] == nil do
          check_update_geoip(self(), ip, id)
        end

        case {v1[:info][:status], status} do
          {:banned, :ok} ->
            time = ts_now - v1[:info][:banned]
            c = Skn.Counter.update_counter(:proxy_reuse_count, 1)
            Skn.Counter.update_counter(:proxy_ip_reused, 1)
            ravg = Skn.Counter.read(:proxy_reuse_avg)
            rmin = Skn.Counter.read(:proxy_reuse_min)
            rmax = Skn.Counter.read(:proxy_reuse_max)
            rmin1 = if rmin == 0, do: time, else: min(time, rmin)
            rmax1 = max(time, rmax)
            ravg1 = trunc((ravg * (c - 1) + time) / c)
            Skn.Counter.write(:proxy_reuse_avg, ravg1)
            Skn.Counter.write(:proxy_reuse_min, rmin1)
            Skn.Counter.write(:proxy_reuse_max, rmax1)

          _ ->
            Skn.Counter.update_counter(:proxy_ip_old, 1)
        end

        pinned_age = ts_now - v1[:info][:pinned]
        pinned_reset = Skn.Config.get(:luminati_pin_reset, 2 * 3600_000)
        pinned_age_min = Skn.Config.get(:luminati_pin_age, 1200_000)
        def_week_max = Skn.Config.get(:luminati_week_per_ip, 2)
        geo = Map.get(v1[:info], :geo, %{"country_code" => "us"})
        cc = if is_map(geo), do: geo["country_code"], else: "us"
        geo_week_max = Skn.Config.get({:luminati_week_per_ip, cc}, def_week_max)
        strict_ip = Skn.Config.get(:luminati_strict_ip, true)
        is_ok = status == :ok or v1[:info][:status] == :ok

        if strict_ip == false or
             (is_ok == true and
                (v1[:info][:pid] == from or
                   ((v1[:info][:pid] == nil and pinned_age > pinned_age_min) or
                      pinned_age > pinned_reset)) and v1[:info][:week] < geo_week_max) do
          Skn.DB.ProxyIP2.update_week(ip, id, from, :keep)
          rpc_reply(h, from, {:check_ack, ip})
        else
          rpc_reply(h, from, {:check_error, ip, v1[:info][:status], v1[:info][:week]})
        end
    end

    {:noreply, state}
  end

  def handle_info({:rpc, h, {:release, from, tid, ips}}, %{id: id} = state) do
    Enum.each(ips, fn ip ->
      Skn.DB.ProxyIP2.update_week(ip, id, nil, :keep)
    end)

    rpc_reply(h, from, {:release_ack, tid})
    {:noreply, state}
  end

  def handle_info({:rpc, h, {:week_done, from, ip}}, %{id: id} = state) do
    ts_now = :erlang.system_time(:millisecond)

    case Skn.DB.ProxyIP2.get(ip) do
      nil ->
        nname = if is_pid(from), do: node(from), else: nil

        info = %{
          status: :ok,
          account: 0,
          week: 1,
          total_account: 0,
          total_week: 1,
          nnode: nname,
          pid: from,
          geo: nil,
          built: 0,
          updated: ts_now,
          pinned: ts_now,
          banned: 0,
          reused: 0,
          created: ts_now,
          total_built: [],
          total_updated: [ts_now],
          total_pinned: [ts_now],
          total_banned: [],
          total_reused: []
        }

        Skn.DB.ProxyIP2.write(ip, id, info)
        rpc_reply(h, from, {:week_done_ack, :continue})

      v ->
        v1 = Skn.DB.ProxyIP2.to_map(v)
        Skn.DB.ProxyIP2.update_week(ip, id, from, 1)
        week_max = Skn.Config.get(:luminati_week_per_ip, 2) - 1
        strict_ip = Skn.Config.get(:luminati_strict_ip, true)

        if strict_ip == true and v1[:info][:week] > week_max do
          rpc_reply(h, from, {:week_done_ack, :change_ip, ip})
        else
          rpc_reply(h, from, {:week_done_ack, :continue, ip})
        end
    end

    {:noreply, state}
  end

  def handle_info({:rpc, _h, {:update, ip, status}}, %{id: id} = state) do
    case Skn.DB.ProxyIP2.update_status(ip, id, status) do
      {:reused, time} ->
        c = Skn.Counter.update_counter(:proxy_reuse_count, 1)
        Skn.Counter.update_counter(:proxy_ip_reused, 1)
        ravg = Skn.Counter.read(:proxy_reuse_avg)
        rmin = Skn.Counter.read(:proxy_reuse_min)
        rmax = Skn.Counter.read(:proxy_reuse_max)
        rmin1 = if rmin == 0, do: time, else: min(time, rmin)
        rmax1 = max(time, rmax)
        ravg1 = trunc((ravg * (c - 1) + time) / c)
        Skn.Counter.write(:proxy_reuse_avg, ravg1)
        Skn.Counter.write(:proxy_reuse_min, rmin1)
        Skn.Counter.write(:proxy_reuse_max, rmax1)

      {:new, :ok} ->
        Skn.Counter.update_counter(:proxy_ip_new, 1)
        check_update_geoip(self(), ip, id)

      {:new, :banned} ->
        Skn.Counter.update_counter(:proxy_ip_banned, 1)
        check_update_geoip(self(), ip, id)

      {:updated, :banned} ->
        Skn.Counter.update_counter(:proxy_ip_banned, 1)

      _ ->
        Skn.Counter.update_counter(:proxy_ip_old, 1)
    end

    {:noreply, state}
  end

  def handle_info({:update_geo, ip, keeper, geo, is_static}, state) do
    Skn.DB.ProxyIP2.update_geo(ip, keeper, geo, is_static)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, %{rk: rk}) do
    Command.Router.delete(rk)
    :ok
  end
end

defmodule Proxy.LocalKeeper do
  use GenServer
  require Logger

  import Skn.Util, only: [
    reset_timer: 3
  ]
  @name :proxy_local_keeper

  defp demonitor(ref) do
    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def unpin_ip(from, ip) when is_binary(ip) do
    send(@name, {:unpin_ip, from, ip})
  end

  def unpin_ip(_from, _ip) do
    :ok
  end

  def pin_ip(from, ip) do
    send(@name, {:pin_ip, from, ip})
  end

  def init([]) do
    :ets.new(:local_keeper_db, [:public, :set, :named_table])
    reset_timer(:schedule_ref, :schedule, 10000)
    {:ok, %{queue: %{}, pend: %{}, tid: 0}}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :badcall}, state}
  end

  def handle_cast(_request, state) do
    {:noreply, state}
  end

  def handle_info(:schedule, %{queue: queue, pend: pend, tid: tid} = state) do
    reset_timer(:schedule_ref, :schedule, 10000)
    ql = Map.to_list(queue)

    {pend1, tid1} =
      Enum.reduce(ql, {pend, tid}, fn {_id, ips}, {p, t} ->
        if is_list(ips) and length(ips) > 0 do
          t1 = if t >= 65535, do: 0, else: t + 1
          Proxy.Keeper.release(self(), t1, ips)
          p1 = Map.put(p, t1, ips)
          {p1, t1}
        else
          {p, t}
        end
      end)

    {:noreply, %{state | queue: %{}, pend: pend1, tid: tid1}}
  end

  def handle_info({:release_ack, tid}, %{pend: pend} = state) do
    pend1 = Map.delete(pend, tid)
    {:noreply, %{state | pend: pend1}}
  end

  def handle_info({:pin_ip, from, ip}, state) do
    case :ets.lookup(:local_keeper_db, from) do
      [{pid, ref1, ip1}] when ip1 != ip ->
        send(self(), {:unpin_ip, pid, ip1})
        :ets.insert(:local_keeper_db, {from, ref1, ip})

      [{_, _, _}] ->
        :ignore

      [] ->
        ref = Process.monitor(from)
        :ets.insert(:local_keeper_db, {from, ref, ip})
    end

    {:noreply, state}
  end

  def handle_info({:unpin_ip, _from, ip}, %{queue: q} = state) do
    id = rem(:erlang.phash2(ip), Proxy.Keeper.size())
    ips = Map.get(q, id, [])
    q1 = Map.put(q, id, :sets.to_list(:sets.from_list([ip | ips])))
    {:noreply, %{state | queue: q1}}
  end

  def handle_info({:DOWN, _ref, :process, from, _reason}, state) do
    case :ets.lookup(:local_keeper_db, from) do
      [{pid, ref1, ip}] when pid == from ->
        demonitor(ref1)
        :ets.delete(:local_keeper_db, from)
        send(self(), {:unpin_ip, from, ip})

      [{_pid, _ref, _ip}] ->
        :ignore

      [] ->
        :ignore
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(_reason, _state) do
    :ok
  end
end

defmodule Proxy.LocalKeeperAck do
  use GenServer
  require Logger
  @name :proxy_local_keeper_ack

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def my_rk() do
    "LUM.KEEPER.LOCAL"
  end

  def init([]) do
    Command.Router.set(my_rk(), self())
    {:ok, %{rk: my_rk()}}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :badarg}, state}
  end

  def handle_cast(_request, state) do
    {:noreply, state}
  end

  def handle_info({:rpc, _h, {:proxy_keeper_reply, from, msg}}, state) do
    send(from, msg)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("drop unknown #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(_reason, %{rk: rk}) do
    Command.Router.delete(rk)
    :ok
  end
end
