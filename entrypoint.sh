#!/bin/bash
set -e

function etcd_creator(){
  local IPADDR="$1"
  local ETCD_NAME="$2"

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --restart=always \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:2379,http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:2380  \
      --listen-peer-urls http://0.0.0.0:2380 \
      --initial-cluster-token etcd-cluster-1 \
      --initial-cluster "${ETCD_NAME}=http://${IPADDR}:2380" \
      --initial-cluster-state new \
      --data-dir /var/lib/etcd
}

function etcd_follower(){
  local IPADDR="$1"
  local ETCD_NAME="$2"
  local ETCD_MEMBER="$(echo "$3" | cut -d ':' -f 1)"
  local PORT="$(echo "$3" | cut -d ':' -f 2)"
  local PROXY="$4"
  local PEER_PORT="2380"
  local ETCD2_MAX_MEMBER_SIZE="5"

  docker pull "${ENV_ETCD_IMAGE}" 1>&2

  # Check if cluster is full
  local ETCD_EXISTED_MEMBER_SIZE="$(curl -sf --retry 10 \
    http://${ETCD_MEMBER}:${PORT}/v2/members | jq '.[] | length')"
  if [[ -z "${ETCD_EXISTED_MEMBER_SIZE}" ]]; then
    echo "Can not connect to the etcd member, exiting..." 1>&2
    sh -c 'docker rm -f k8sup-etcd' >/dev/null 2>&1 || true
    exit 1
  fi
  if [[ "${PROXY}" == "off" ]] \
   && [[ "${ETCD_EXISTED_MEMBER_SIZE}" -ge "${ETCD2_MAX_MEMBER_SIZE}" ]]; then
    # If cluster is not full, proxy mode off. If cluster is full, proxy mode on
    PROXY="on"
  fi

  # If cluster is not full, Use locker (etcd atomic CAS) to get a privilege for joining etcd cluster
  local LOCKER_ETCD_KEY="vsdx/locker-etcd-member-add"
  until [[ "${PROXY}" == "on" ]] || curl -sf \
    "http://${ETCD_MEMBER}:${PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevExist=false" \
    -XPUT -d value="${IPADDR}" 1>&2; do
      echo "Another node is joining etcd cluster, Waiting for it done..." 1>&2
      sleep 1

      # Check if cluster is full
      local ETCD_EXISTED_MEMBER_SIZE="$(curl -sf --retry 10 \
        http://${ETCD_MEMBER}:${PORT}/v2/members | jq '.[] | length')"
      if [ "${ETCD_EXISTED_MEMBER_SIZE}" -ge "${ETCD2_MAX_MEMBER_SIZE}" ]; then
        # If cluster is not full, proxy mode off. If cluster is full, proxy mode on
        PROXY="on"
      fi
  done
  if [[ "${PROXY}" == "off" ]]; then
    # Run etcd member add
    curl -s "http://${ETCD_MEMBER}:${PORT}/v2/members" -XPOST \
      -H "Content-Type: application/json" -d "{\"peerURLs\":[\"http://${IPADDR}:${PEER_PORT}\"]}" 1>&2
  fi

  # Update Endpoints to etcd2 parameters
  local MEMBERS="$(curl -s http://${ETCD_MEMBER}:${PORT}/v2/members)"
  local SIZE="$(echo "${MEMBERS}" | jq '.[] | length')"
  local PEER_IDX=0
  local ENDPOINTS="${ETCD_NAME}=http://${IPADDR}:${PEER_PORT}"
  for PEER_IDX in $(seq 0 "$((${SIZE}-1))"); do
    local PEER_NAME="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].name")"
    local PEER_URL="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].peerURLs[]" | head -n 1)"
    if [ -n "${PEER_URL}" ] && [ "${PEER_URL}" != "http://${IPADDR}:${PEER_PORT}" ]; then
      ENDPOINTS="${ENDPOINTS},${PEER_NAME}=${PEER_URL}"
    fi
  done

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --restart=always \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:2379,http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:2380 \
      --listen-peer-urls http://0.0.0.0:2380 \
      --initial-cluster-token etcd-cluster-1 \
      --initial-cluster "${ENDPOINTS}" \
      --initial-cluster-state existing \
      --data-dir /var/lib/etcd \
      --proxy "${PROXY}"


  if [ "${PROXY}" == "off" ]; then
    # Unlock and release the privilege for joining etcd cluster
    until curl -sf "http://${ETCD_MEMBER}:${PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevValue=${IPADDR}" -XDELETE 1>&2; do
        sleep 1
    done
  fi
}

function flanneld(){
  local IPADDR="$1"
  local ETCD_CID="$2"
  local ROLE="$3"

  if [[ "${ROLE}" == "creator" ]]; then
    echo "Setting flannel parameters to etcd"
    local KERNEL_SHORT_VERSION="$(uname -r | cut -d '.' -f 1-2)"
    local VXLAN="$(echo "${KERNEL_SHORT_VERSION} >= 3.9" | bc)"
    if [ "${VXLAN}" -eq "1" ] && [ "$(modinfo vxlan &>/dev/null; echo $?)" -eq "0" ]; then
      local FLANNDL_CONF="$(cat /go/flannel-conf/network-vxlan.json)"
    else
      local FLANNDL_CONF="$(cat /go/flannel-conf/network.json)"
    fi
    docker exec -d \
      "${ETCD_CID}" \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:2379 \
      set /coreos.com/network/config "${FLANNDL_CONF}"
  fi

  docker run \
    -d \
    --name k8sup-flannel \
    --net=host \
    --privileged \
    --restart=always \
    -v /dev/net:/dev/net \
    -v /run/flannel:/run/flannel \
    "${ENV_FLANNELD_IMAGE}" \
    /opt/bin/flanneld \
      --etcd-endpoints="http://${IPADDR}:4001" \
      --iface="${IPADDR}"
}

function show_usage(){
  USAGE="Usage: ${0##*/} [options...]
Options:
-i, --ip=IPADDR           Host IP address (Required)
-c, --cluster=CLUSTER_ID  Join a specified cluster
-n, --new                 Force to start a new cluster
-p, --proxy               Force to run as etcd and k8s proxy
-h, --help                This help text
"

  echo "${USAGE}"
}

function get_options(){
  local PROGNAME="${0##*/}"
  local SHORTOPTS="i:c:nph"
  local LONGOPTS="ip:,cluster:,new,proxy,help"
  local PARSED_OPTIONS=""

  PARSED_OPTIONS="$(getopt -o "${SHORTOPTS}" --long "${LONGOPTS}" -n "${PROGNAME}" -- "$@")" || exit 1
  eval set -- "${PARSED_OPTIONS}"

  # extract options and their arguments into variables.
  while true ; do
      case "$1" in
          -i|--ip)
              export EX_IPADDR="$2"
              shift 2
              ;;
          -c|--cluster)
              export EX_CLUSTER_ID="$2"
              shift 2
              ;;
          -n|--new)
              export EX_NEW_CLUSTER="true"
              shift
              ;;
          -p|--proxy)
              export EX_PROXY="on"
              shift
              ;;
          -h|--help)
              show_usage
              exit 0
              shift
              ;;
          --)
              shift
              break
              ;;
          *)
              echo "Option error!" 1>&2
              echo $1
              exit 1
              ;;
      esac
  done


  if [[ -z "${EX_IPADDR}" ]] || \
   [[ -z "$(ip addr | sed -nr "s/.*inet ([^ ]+)\/.*/\1/p" | grep -w "${EX_IPADDR}")" ]]; then
    echo "IP address error, exiting..." 1>&2
    exit 1
  fi

  if [[ -n "${EX_CLUSTER_ID}" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either join a existed etcd cluster or start a new etcd cluster, exiting..." 1>&2
    exit 1
  fi
  if [[ "${EX_PROXY}" == "on" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either run as proxy or start a new etcd cluster, exiting..." 1>&2
    exit 1
  fi

  if [[ "${EX_PROXY}" != "on" ]]; then
    export EX_PROXY="off"
  fi
}

function main(){

  export ENV_ETCD_VERSION="3.0.4"
  export ENV_FLANNELD_VERSION="0.5.5"
#  export ENV_K8S_VERSION="1.3.4"
  export ENV_ETCD_IMAGE="quay.io/coreos/etcd:v${ENV_ETCD_VERSION}"
  export ENV_FLANNELD_IMAGE="quay.io/coreos/flannel:${ENV_FLANNELD_VERSION}"
#  export ENV_HYPERKUBE_IMAGE="gcr.io/google_containers/hyperkube-amd64:v${ENV_K8S_VERSION}"

  get_options "$@"
  local IPADDR="${EX_IPADDR}"
  local CLUSTER_ID="${EX_CLUSTER_ID}"
  local NEW_CLUSTER="${EX_NEW_CLUSTER}"
  local PROXY="${EX_PROXY}"

  if [[ "${NEW_CLUSTER}" != "true" ]]; then
    # If do not force to start an etcd cluster, make a discovery.
    echo "Discovering etcd cluster..."
    local DISCOVERY_RESULTS="$(go run /go/dnssd/browsing.go)"
    echo "${DISCOVERY_RESULTS}"

    # If find an etcd cluster that user specified or find only one etcd cluster, join it instead of starting a new.
    local EXISTED_ETCD_MEMBER=""
    if [[ -n "${CLUSTER_ID}" ]]; then
      EXISTED_ETCD_MEMBER="$(echo "${DISCOVERY_RESULTS}" | grep -w "${CLUSTER_ID}" | head -n 1 | awk '{print $2}')"
      if [[ -z "${EXISTED_ETCD_MEMBER}" ]]; then
        echo "No such the etcd cluster that user specified, exiting..." 1>&2
        exit 1
      fi
    elif [[ "$(echo "${DISCOVERY_RESULTS}" | wc -l)" -eq "1" ]]; then
      EXISTED_ETCD_MEMBER="$(echo "${DISCOVERY_RESULTS}" | awk '{print $2}')"
    fi
    echo "etcd member: ${EXISTED_ETCD_MEMBER}"
  fi

  if [[ -z "${EXISTED_ETCD_MEMBER}" ]] && [[ "${PROXY}" == "on" ]]; then
    echo "Proxy mode needs a cluster to join, exiting..." 1>&2
    exit 1
  fi

  local ROLE=""
  if [[ -z "${EXISTED_ETCD_MEMBER}" ]] || [[ "${NEW_CLUSTER}" == "true" ]]; then
    local ROLE="creator"
  else
    local ROLE="follower"
  fi

  echo "Copy cni plugins"
  cp -rf bin /opt/cni
  mkdir -p /etc/cni/net.d/
  cp -f /go/cni-conf/10-containernet.conf /etc/cni/net.d/
  cp -f /go/cni-conf/99-loopback.conf /etc/cni/net.d/
  mkdir -p /var/lib/cni/networks/mynet; echo "" > /var/lib/cni/networks/mynet/last_reserved_ip

  sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'ip link delete cni0' >/dev/null 2>&1 || true

  local NODE_NAME="node-$(uuidgen -r | cut -c1-6)"

  echo "Running etcd"
  local ETCD_CID=""
  if [[ "${ROLE}" == "creator" ]]; then
    ETCD_CID=$(etcd_creator "${IPADDR}" "${NODE_NAME}") || exit 1
  else
    ETCD_CID=$(etcd_follower "${IPADDR}" "${NODE_NAME}" "${EXISTED_ETCD_MEMBER}" "${PROXY}") || exit 1
  fi

  until curl -s 127.0.0.1:2379/v2/keys 1>/dev/null 2>&1; do
    echo "Waiting for etcd ready..."
    sleep 1
  done
  echo "Running flanneld"
  flanneld "${IPADDR}" "${ETCD_CID}" "${ROLE}"

  #echo "Running Kubernetes"
  local APISERVER="$(echo "${EXISTED_ETCD_MEMBER}" | cut -d ':' -f 1):8080"
  if [[ "${PROXY}" == "on" ]]; then
    /go/kube-up --ip="${IPADDR}" --worker --apiserver="${APISERVER}"
  else
    /go/kube-up --ip="${IPADDR}"
  fi


  local CLUSTER_ID="$(curl 127.0.0.1:2379/v2/members -vv 2>&1 | grep 'X-Etcd-Cluster-Id' | sed -n "s/.*: \(.*\)$/\1/p" | tr -d '\r')"
  echo -e "etcd CLUSTER_ID: \033[1;31m${CLUSTER_ID}\033[0m"
  go run /go/dnssd/registering.go "${NODE_NAME}" "${IPADDR}" "2379" "${CLUSTER_ID}"

}

main "$@"
