#!/bin/bash

uuid=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 5 | head -n 1)
case $1 in
remsh)
    iex --sname ${uuid}_proxy@erlnode1 --remsh proxy@erlnode1 --erl "-setcookie proxy"
    ;;
*)
    CONFIG_FILE=priv/proxy.config iex --sname proxy@erlnode1 --erl "-setcookie proxy" -S mix
    ;;
esac
