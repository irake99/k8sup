# bash functions
source "$(dirname "$0")/env.sh" || { echo 'Can not load the env.sh file, exiting...' >&2 && exit 1 ; }

function hold_until_kube_apiserver_started(){
  until curl-k8s -sf "https://10.0.0.1:443/version" &>/dev/null; do
    sleep 1
  done
}
