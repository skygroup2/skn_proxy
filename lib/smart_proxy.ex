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
      opts = [{:linger, {false, 0}}, {:reuseaddr, true}, {:insecure, true}, {:pool, false}, {:recv_timeout, 35000}, {:connect_timeout, 15000}, {:ssl_options, [{:versions, [:'tlsv1.2']}, {:reuse_sessions, false}]}]
      headers = %{"Connection" => "close", "Accept-Encoding" => "gzip"}
      {:ok, x} = HTTPoison.get(url, headers, [hackney: opts])
      :binary.split(HackneyEx.decode_gzip(x), "\r\n", [:global])
    catch
      _,_ ->
        []
    end
  end

end