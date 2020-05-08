defmodule Skn.DB.ProxyList do
  use Bitwise
  require Skn.Proxy.Repo
  require Logger

  def to_file(file, tag \\ nil) do
    data = :mnesia.dirty_all_keys(:proxy_status) |> Enum.map(fn x -> get(x) end)
    data = if tag != nil do
      Enum.filter(data, fn x -> x[:tag] == tag end)
    else
      data
    end
    Skn.Util.write_term_db(file, data)
  end

  def from_file(file) do
    {:ok, data} = :file.consult file
    Enum.each data, fn x -> write(x) end
  end

  def to_map(c) do
    %{
      id: Skn.Proxy.Repo.proxy_status(c, :id),
      ip: Skn.Proxy.Repo.proxy_status(c, :ip),
      tag: Skn.Proxy.Repo.proxy_status(c, :tag),
      info: Skn.Proxy.Repo.proxy_status(c, :info),
      assign: Skn.Proxy.Repo.proxy_status(c, :assign)
    }
  end

  def get(id) do
    case :mnesia.dirty_read(:proxy_status, id) do
      [c] -> to_map(c)
      [] -> nil
    end
  end

  def write(%{id: id, ip: ip, tag: tag, assign: assign, info: info}) do
    obj = Skn.Proxy.Repo.proxy_status(id: id, ip: ip, tag: tag, info: info, assign: assign)
    :mnesia.dirty_write(:proxy_status, obj)
  end

  def delete(id) do
    :mnesia.dirty_delete(:proxy_status, id)
  end

  def get_ip(ip) do
    cx = :mnesia.dirty_match_object(:proxy_status, {:proxy_status, :_, ip, :_, :_, :_})
    Enum.map cx, fn c -> to_map(c) end
  end

  def merge_data(id, data) do
    case get(id) do
      %{info: info} = c ->
        new_data = Map.merge(info, data)
        write(%{c| info: new_data})
      nil ->
        :ok
    end
  end

  def get_data(id, default) do
    case get(id) do
      %{info: info} -> info
      nil -> default
    end
  end

  def get_data_attr(id, key, default) do
    case get(id) do
      %{info: info} ->
        Map.get(info, key, default)
      nil ->
        default
    end
  end

  def replace_lum(account, zone, password) do
    Skn.DB.ProxyList.list_tag(:super)
    |> Enum.each(fn x ->
      case x do
        %{id: {old_proxy, {:lum, _user, _password}}} ->
          new_id = {old_proxy, {:lum, "lum-customer-#{account}-zone-#{zone}", password}}
          Skn.DB.ProxyList.delete(x[:id])
          Skn.DB.ProxyList.write(%{x| id: new_id})
        _ ->
          :skip
      end
    end)
  end

  def list_all_tag(tag) do
    ms = [{{:proxy_status, :_, :_, :"$1", :_, :_}, [{:==, :"$1", tag}], [:"$_"]}]
    :mnesia.dirty_select(:proxy_status, ms)
    |> Enum.map(fn x -> to_map(x) end)
  end

  def list_tag(tag, assign \\ nil) do
    ms = cond do
      assign != nil ->
        [{
          {:proxy_status, :_, :_, :"$1", :"$2", :_},
          [{:andalso, {:==, :"$1", tag}, {:==, :"$2", assign}}],
          [:"$_"]
        }]
      true ->
        [{{:proxy_status, :_, :_, :"$1", :_, :_}, [{:==, :"$1", tag}], [:"$_"]}]
    end
    :mnesia.dirty_select(:proxy_status, ms)
    |> Enum.map(fn x -> to_map(x) end)
  end

end