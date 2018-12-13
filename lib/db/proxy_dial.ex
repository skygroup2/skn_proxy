defmodule Skn.DB.ProxyDial do
  require Skn.Proxy.Repo
  @doc """
    info:
      - active: []
      - ssh_ip
      - ssh_port
      - proxy_ip
  """
  def read(ip) do
    case :mnesia.dirty_read(:proxy_dial, ip) do
      [c| _] ->
        to_map(c)
      _ ->
        nil
    end
  end

  def write(%{id: id, ssh: ssh, ts_reset: ts_reset, ts_active: ts_active, info: info}) do
    obj = Skn.Proxy.Repo.proxy_dial(id: id, ssh: ssh, ts_reset: ts_reset, ts_active: ts_active, info: info)
    :mnesia.dirty_write(:proxy_dial, obj)
  end

  def select() do
    []
  end

  def all() do
    Enum.map(:mnesia.dirty_all_keys(:proxy_dial), fn x -> to_map(x) end)
  end

  def delete(id) do
    :mnesia.dirty_delete(:proxy_dial, id)
  end

  def delete_by(proxy, ssh) do
    v = :mnesia.dirty_index_read(:proxy_dial, ssh, 3)
    Enum.each v, fn x ->
      pp = to_map(x)
      if pp.id != proxy do
        delete(pp.id)
      end
    end
  end

  def to_map({:proxy_dial, id, ssh, ts_reset, ts_active, info}) do
    %{id: id, ssh: ssh, ts_reset: ts_reset, ts_active: ts_active, info: info}
  end
end