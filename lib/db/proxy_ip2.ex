defmodule Skn.DB.ProxyIP2 do
  require Skn.Proxy.Repo

  def write(ip, keeper, info) do
    obj = Skn.Proxy.Repo.proxy_ip2(id: ip, keeper: keeper, info: info)
    :mnesia.dirty_write(:proxy_ip2, obj)
  end

  def get_by(keeper) do
    :mnesia.dirty_match_object(:proxy_ip2, {:proxy_ip2, :_, keeper, :_})
  end

  def get_all() do
    :mnesia.dirty_match_object(:proxy_ip2, {:proxy_ip2, :_, :_, :_})
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