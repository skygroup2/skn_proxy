defmodule Skn.Proxy do
  use Application
  require Logger

  def start(_type, _args) do
    ret = Skn.Proxy.Sup.start_link()
    ret
  end

  def stop(state) do
    Logger.info("Proxy is terminated by #{inspect(state)}")
    :mnesia.sync_log()
  end
end