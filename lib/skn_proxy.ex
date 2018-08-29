defmodule Skn.Proxy.Sup do
  def start_proxy_hook() do
    http_port = Skn.Config.get(:web_proxy_port, nil)
    if is_integer(http_port) and http_port > 1024 and http_port < 65535 do
      dispatch = :cowboy_router.compile([{:_, [{:_, Skn.Proxy.RestApi, []}]}])
      :cowboy.start_clear(:http, [{:port, http_port}], %{env: %{dispatch: dispatch}})
    else
      {:ok, :ignore}
    end
  end
end