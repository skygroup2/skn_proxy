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
      opts = %{
        recv_timeout: 25000,
        connect_timeout: 35000,
        retry: 0,
        retry_timeout: 5000,
        transport_opts: [{:reuseaddr, true}, {:reuse_sessions, false}, {:linger, {false, 0}}, {:versions, [:"tlsv1.2"]}]
      }
      headers = %{"connection" => "close", "accept-encoding" => "gzip"}
      x = GunEx.http_request("GET", url, headers, "", opts, nil)
      String.split(GunEx.decode_gzip(x), ["\r\n", "\n"])
      |> Enum.map(fn x -> String.trim(x) end)
    catch
      _,_ ->
        []
    end
  end

end