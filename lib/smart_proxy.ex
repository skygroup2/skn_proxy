defmodule SmartProxy do
  @moduledoc """
    Implement API for smartproxy.io stick/ random
  """

  def get_stick_proxy() do
    http_get_proxy_list("https://www.smartproxy.io/smartproxy_sticky_proxy.txt")
  end

  def get_random_proxy() do
    http_get_proxy_list("https://www.smartproxy.io/smartproxy_random_proxy.txt")
  end

  def http_get_proxy_list(url) do
    try do
      {:ok, x} = HTTPoison.get(url)
      :binary.split(x.body, "\r\n", [:global])
    catch
      _,_ ->
        []
    end
  end

end