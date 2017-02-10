#!/bin/bash
set -e
source "$(dirname "$0")/runcom" || { echo 'Can not load the rumcom file, exiting...' >&2 && exit 1 ; }
trap 'cleanup $?' EXIT
#---

function cleanup(){
  local RC="$1"
  if [[ "${RC}" -ne 0 ]]; then
    local LOGNAME="k8sup-$(date +"%Y%m%d%H%M%S-%N")"
    mkdir -p "/etc/kubernetes/logs"
    docker logs k8sup &>"/etc/kubernetes/logs/${LOGNAME}.log"
    docker inspect k8sup &>"/etc/kubernetes/logs/${LOGNAME}.json"
    docker rm -f k8sup
  else
    docker stop k8sup
  fi
}

function get_alive_etcd_member_size(){
  local MEMBER_LIST="$1"
  local MEMBER_CLIENT_ADDR_LIST="$(echo "${MEMBER_LIST}" | jq -r ".members[].clientURLs[0]" | grep -v 'null')"
  local ALIVE_ETCD_MEMBER_SIZE="0"
  local MEMBER

  for MEMBER in ${MEMBER_CLIENT_ADDR_LIST}; do
    if curl -s -m 3 "${MEMBER}/health" &>/dev/null; then
      ((ALIVE_ETCD_MEMBER_SIZE++))
    fi
  done
  echo "${ALIVE_ETCD_MEMBER_SIZE}"
}

function etcd_creator(){
  local IPADDR="$1"
  local ETCD_NAME="$2"
  local CLUSTER_ID="$3"
  local MAX_ETCD_MEMBER_SIZE="$4"
  local CLIENT_PORT="$5"
  local NEW_CLUSTER="$6"
  local RESTORE_ETCD="$7"
  local PEER_PORT="2380"
  local ETCD_PATH="k8sup/cluster"
  local RESTART_WITH_OLD_DATA

  if [[ "${RESTORE_ETCD}" == "true" ]]; then
    local RESTORE_CMD="--force-new-cluster=true"
    RESTART_WITH_OLD_DATA="true"
  fi

  if [[ -d "/var/lib/etcd/member" ]] || [[ -d "/var/lib/etcd/proxy" ]]; then
    RESTART_WITH_OLD_DATA="true"
  else
    RESTART_WITH_OLD_DATA="false"
  fi

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      ${RESTORE_CMD} \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:${CLIENT_PORT},http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:${CLIENT_PORT},http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:${PEER_PORT}  \
      --listen-peer-urls http://0.0.0.0:${PEER_PORT} \
      --initial-cluster "${ETCD_NAME}=http://${IPADDR}:${PEER_PORT}" \
      --initial-cluster-state new \
      --data-dir /var/lib/etcd \
      --proxy off || return 1

  echo "Waiting for all etcd members ready..." 1>&2
  until curl -sf -m 1 127.0.0.1:${CLIENT_PORT}/v2/keys &>/dev/null; do
    sleep 3
    [[ -z "$(docker ps | grep k8sup-etcd)" ]] && docker start k8sup-etcd &>/dev/null
  done

  if [[ "${RESTART_WITH_OLD_DATA}" == "false" ]]; then
    curl -s "127.0.0.1:${CLIENT_PORT}/v2/keys/${ETCD_PATH}/max_etcd_member_size" -XPUT -d value="${MAX_ETCD_MEMBER_SIZE}" 1>&2

    if [[ -z "${CLUSTER_ID}" ]]; then
      CLUSTER_ID="$(uuidgen -r | tr -d '-' | cut -c1-16)"
    fi
    curl -sf "http://127.0.0.1:${CLIENT_PORT}/v2/keys/${ETCD_PATH}/clusterid" -XPUT -d value="${CLUSTER_ID}" 1>/dev/null
  fi

  if [[ "${RESTORE_ETCD}" == "true" ]]; then
    echo "etcd data has successfully restored, exiting..." 1>&2
    docker stop k8sup-etcd 1>/dev/null
    docker rm k8sup-etcd 1>/dev/null
    docker rm -f k8sup 1>/dev/null
    exit 0
  fi
}

function etcd_follower(){
  local IPADDR="$1"
  local ETCD_NAME="$2"
  local ETCD_NODE_LIST="$3"
  local ETCD_NODE=""
  local CLIENT_PORT=""
  local PROXY="$4"
  local PEER_PORT="2380"
  local ETCD_PATH="k8sup/cluster"
  local MIN_ETCD_MEMBER_SIZE="1"
  local ETCD_EXISTED_MEMBER_SIZE
  local NODE

  # Get an existed etcd member
  until [[ -n "${ETCD_NODE}" ]] && [[ -n "${CLIENT_PORT}" ]]; do
    for NODE in ${ETCD_NODE_LIST}; do
      if curl -s -m 3 "${NODE}/health" &>/dev/null; then
        ETCD_NODE="$(echo "${NODE}" | cut -d ':' -f 1)"
        CLIENT_PORT="$(echo "${NODE}" | cut -d ':' -f 2)"
        break
      fi
    done
    echo "Waiting for any etcd member started..." 1>&2
    sleep 1
  done

  # Prevent the cap of etcd member size less then 3
  local MAX_ETCD_MEMBER_SIZE="$(curl -s --retry 10 "${ETCD_NODE}:${CLIENT_PORT}/v2/keys/${ETCD_PATH}/max_etcd_member_size" 2>/dev/null \
                                | jq -r '.node.value')"
  if [[ "${MAX_ETCD_MEMBER_SIZE}" -lt "${MIN_ETCD_MEMBER_SIZE}" ]]; then
    MAX_ETCD_MEMBER_SIZE="${MIN_ETCD_MEMBER_SIZE}"
    curl -s "${ETCD_NODE}:${CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
      -XPUT -d value="${MAX_ETCD_MEMBER_SIZE}" 1>&2
  fi

  docker pull "${ENV_ETCD_IMAGE}" &>/dev/null

  # Check if this node has joined etcd this cluster
  local MEMBERS="$(curl -sf --retry 10 http://${ETCD_NODE}:${CLIENT_PORT}/v2/members)"
  if [[ -z "${MEMBERS}" ]] || [[ -z "${MAX_ETCD_MEMBER_SIZE}" ]]; then
    echo "Can not connect to the etcd member, exiting..." 1>&2
    sh -c 'docker rm -f k8sup-etcd' >/dev/null 2>&1 || true
    exit 1
  fi
  if [[ "${MEMBERS}" == *"${IPADDR}:${CLIENT_PORT}"* ]]; then
    local ALREADY_MEMBER="true"
    PROXY="off"
  else
    local ALREADY_MEMBER="false"
    rm -rf "/var/lib/etcd/"*
  fi

  if [[ "${ALREADY_MEMBER}" != "true" ]]; then
    ETCD_EXISTED_MEMBER_SIZE="$(get_alive_etcd_member_size "${MEMBERS}")"

    # Check if cluster is full
    if [[ "${PROXY}" == "off" ]] \
     && [[ "${ETCD_EXISTED_MEMBER_SIZE}" -ge "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      # If cluster is not full, proxy mode off. If cluster is full, proxy mode on
      PROXY="on"
    fi

    # If cluster is not full, Use locker (etcd atomic CAS) to get a privilege for joining etcd cluster
    local LOCKER_ETCD_KEY="locker-etcd-member-add"
    local LOCKER_URL="http://${ETCD_NODE}:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}"
    until [[ "${PROXY}" == "on" ]] \
      || [[ "$(curl -sf "${LOCKER_URL}" | jq -r '.node.value')" == "${IPADDR}" ]] \
      || curl -sf "${LOCKER_URL}?prevExist=false" \
         -XPUT -d value="${IPADDR}" 1>&2; do
        echo "Another node is joining etcd cluster, Waiting for it done..." 1>&2
        sleep 1

        # Check if cluster is full
        MEMBERS="$(curl -sf --retry 10 http://${ETCD_NODE}:${CLIENT_PORT}/v2/members)"
        local ETCD_EXISTED_MEMBER_SIZE="$(get_alive_etcd_member_size "${MEMBERS}")"
        if [ "${ETCD_EXISTED_MEMBER_SIZE}" -ge "${MAX_ETCD_MEMBER_SIZE}" ]; then
          # If cluster is not full, proxy mode off. If cluster is full, proxy mode on
          PROXY="on"
        fi
    done
    if [[ "${PROXY}" == "off" ]]; then
      # Check if etcd name is duplicate in cluster
      if echo "${MEMBERS}" | jq -r '.members[].name' | grep -w "${ETCD_NAME}"; then
        echo "Found duplicate etcd name, exiting..." 1>&2
        # Unlock and release the privilege for joining etcd cluster
        until curl -sf "${LOCKER_URL}?prevValue=${IPADDR}" -XDELETE &>/dev/null; do
            sleep 1
        done
        return 1
      fi
      # Run etcd member add
      curl -s "http://${ETCD_NODE}:${CLIENT_PORT}/v2/members" -XPOST \
        -H "Content-Type: application/json" -d "{\"peerURLs\":[\"http://${IPADDR}:${PEER_PORT}\"]}" 1>&2
    fi
  fi

  # Update Endpoints to etcd2 parameters
  MEMBERS="$(curl -sf --retry 10 http://${ETCD_NODE}:${CLIENT_PORT}/v2/members)"
  local SIZE="$(echo "${MEMBERS}" | jq '.[] | length')"
  local PEER_IDX=0
  local ENDPOINTS="${ETCD_NAME}=http://${IPADDR}:${PEER_PORT}"
  for PEER_IDX in $(seq 0 "$((${SIZE}-1))"); do
    local PEER_NAME="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].name")"
    local PEER_URL="$(echo "${MEMBERS}" | jq -r ".members["${PEER_IDX}"].peerURLs[0]")"
    if [ -n "${PEER_URL}" ] && [ "${PEER_URL}" != "http://${IPADDR}:${PEER_PORT}" ]; then
      ENDPOINTS="${ENDPOINTS},${PEER_NAME}=${PEER_URL}"
    fi
  done

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:${CLIENT_PORT},http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:${CLIENT_PORT},http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:${PEER_PORT} \
      --listen-peer-urls http://0.0.0.0:${PEER_PORT} \
      --initial-cluster-token etcd-cluster-1 \
      --initial-cluster "${ENDPOINTS}" \
      --initial-cluster-state existing \
      --data-dir /var/lib/etcd \
      --proxy "${PROXY}" || return 1


  if [[ "${ALREADY_MEMBER}" != "true" ]] && [[ "${PROXY}" == "off" ]]; then
    # Unlock and release the privilege for joining etcd cluster
    until curl -sf "${LOCKER_URL}?prevValue=${IPADDR}" -XDELETE 1>&2; do
        sleep 1
    done
  fi

  echo "Waiting for all etcd members ready..." 1>&2
  until curl -sf -m 1 127.0.0.1:${CLIENT_PORT}/v2/keys &>/dev/null; do
    sleep 3
  done
}

function wait_etcd_cluster_healthy(){
  local ETCD_CLIENT_PORT="$1"

  echo "Waiting until etcd cluster is healthy..." 1>&2
  until [[ \
    "$(docker exec \
       k8sup-etcd \
       /usr/local/bin/etcdctl \
       --endpoints http://127.0.0.1:${ETCD_CLIENT_PORT} \
       cluster-health \
        | grep 'cluster is' | awk '{print $3}')" == "healthy" ]]; do
    sleep 3
    [[ -z "$(docker ps | grep k8sup-etcd)" ]] && docker start k8sup-etcd &>/dev/null
  done

}

function flanneld(){
  local IPADDR="$1"
  local ETCD_CLIENT_PORT="$2"
  local ROLE="$3"

  if [[ "${ROLE}" == "creator" ]]; then
    echo "Setting flannel parameters to etcd"
    local MIN_KERNEL_VER="3.9"
    local KERNEL_VER="$(uname -r)"

    if [[ "$(echo -e "${MIN_KERNEL_VER}\n${KERNEL_VER}" | sort -V | head -n 1)" == "${MIN_KERNEL_VER}" ]]; then
      local KENNEL_VER_MEETS="true"
    fi

    if [[ "${KENNEL_VER_MEETS}" == "true" ]] && \
     [[ "$(modinfo vxlan &>/dev/null; echo $?)" -eq "0" ]] && \
     [[ -n "$(ip link add type vxlan help 2>&1 | grep vxlan)" ]]; then
      local FLANNDL_CONF="$(cat /go/flannel-conf/network-vxlan.json)"
    else
      local FLANNDL_CONF="$(cat /go/flannel-conf/network.json)"
    fi
    docker exec -d \
      k8sup-etcd \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:${ETCD_CLIENT_PORT} \
      set /coreos.com/network/config "${FLANNDL_CONF}"
  fi

  docker run \
    -d \
    --name k8sup-flannel \
    --net=host \
    --privileged \
    -v /dev/net:/dev/net \
    -v /run/flannel:/run/flannel \
    "${ENV_FLANNELD_IMAGE}" \
    /opt/bin/flanneld \
      --etcd-endpoints="http://${IPADDR}:${ETCD_CLIENT_PORT}" \
      --iface="${IPADDR}"
}

function get_ipaddr_and_mask_from_netinfo(){
  local NETINFO="$1"
  local IPMASK_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}"
  local IP_AND_MASK=""

  if [[ -z "${NETINFO}" ]]; then
    echo "Getting network info error, exiting..." 1>&2
    exit 1
  fi

  # If NETINFO is NIC name
  IP_AND_MASK="$(ip addr show "${NETINFO}" 2>/dev/null | grep -o "${IPMASK_PATTERN}" 2>/dev/null | head -n 1)"
  if [[ -n "${IP_AND_MASK}" ]] ; then
    echo "${IP_AND_MASK}"
    return 0
  fi

  # If NETINFO is an IP address
  IP_AND_MASK="$(ip addr | grep -o "${NETINFO}\/[0-9]\{1,2\}" 2>/dev/null)"
  if [[ -n "${IP_AND_MASK}" ]] ; then
    echo "${IP_AND_MASK}"
    return 0
  fi

  # If NETINFO is SubnetID/MASK
  echo "${NETINFO}" | grep -o "${IPMASK_PATTERN}" &>/dev/null || { echo "Wrong NETINFO, exiting..." 1>&2 && exit 1; }
  local HOST_NET_LIST="$(ip addr show | grep -o "${IPMASK_PATTERN}")"
  local HOST_NET=""
  for NET in ${HOST_NET_LIST}; do
    HOST_NET="$(get_subnet_id_and_mask "${NET}")"
    if [[ "${NETINFO}" == "${HOST_NET}" ]]; then
      IP_AND_MASK="${NET}"
      break
    fi
  done

  if [[ -z "${IP_AND_MASK}" ]]; then
    echo "No such host IP address, exiting..." 1>&2
    exit 1
  fi

  echo "${IP_AND_MASK}"
}

function get_network_by_cluster_id(){
  local CLUSTER_ID="$1"
  local IPMASK_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}"
  local NETWORK
  local NetworkID
  local DISCOVERY_RESULTS

  if [[ -n "${CLUSTER_ID}" ]]; then
    DISCOVERY_RESULTS="$(/go/dnssd/browsing | grep -w "clusterID=${CLUSTER_ID}" | grep -w 'etcdProxy=off')" || true
  else
    DISCOVERY_RESULTS="$(/go/dnssd/browsing | grep -w 'etcdProxy=off')" || true
    CLUSTER_ID="$(echo "${DISCOVERY_RESULTS}" | sed -n "s/.*clusterID=\([[:alnum:]_-]*\).*/\1/p"| uniq)"
    if [[ "$(echo "${CLUSTER_ID}" | wc -l)" -gt "1" ]]; then
      echo "${DISCOVERY_RESULTS}" 1>&2
      echo "More than 1 cluster are found, please specify '--network' or '--cluster', exiting..." 1>&2
      return 1
    fi
  fi
  NetworkID="$(echo "${DISCOVERY_RESULTS}" | sed -n "s/.*NetworkID=\(${IPMASK_PATTERN}\).*/\1/p" | uniq)"
  if [[ "$(echo "${NetworkID}" | wc -l)" -gt "1" ]]; then
    echo "${DISCOVERY_RESULTS}" 1>&2
    echo "Same cluster ID: ${CLUSTER_ID} in different network, please specify '--network', exiting..." 1>&2
    return 1
  fi
  local HOST_NET_LIST="$(ip addr show | grep -o "${IPMASK_PATTERN}")"
  local HOST_NET=""
  local NET=""
  for NET in ${HOST_NET_LIST}; do
    HOST_NET="$(get_subnet_id_and_mask "${NET}")"
    if [[ "${NetworkID}" == "${HOST_NET}" ]]; then
      NETWORK="${NetworkID}"
      break
    fi
  done
  if [[ "${NETWORK}" != "${NetworkID}" ]]; then
    echo "This node does not have ${NETWORK} network, exiting..." 1>&2
    return 1
  fi

  echo "${NETWORK}"
  return 0
}

function kube_up(){
  local CONFIG_FILE="$1"
  source "${CONFIG_FILE}" || exit 1

  local IPADDR="${EX_IPADDR}" && unset EX_IPADDR
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local REGISTRY="${EX_REGISTRY}" && unset EX_REGISTRY
  local FORCED_WORKER="${EX_FORCED_WORKER}" && unset EX_FORCED_WORKER
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}" && unset EX_ETCD_CLIENT_PORT
  local ENABLE_KEYSTONE="${EX_ENABLE_KEYSTONE}" && unset EX_ENABLE_KEYSTONE

  bash -c 'docker stop k8sup-certs k8sup-kubelet' &>/dev/null || true
  bash -c 'docker rm k8sup-certs k8sup-kubelet' &>/dev/null || true

  [[ -n "$(docker ps | grep -w 'k8sup-flannel')" ]] \
  && curl -sf -m 3 127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys &>/dev/null \
  || { echo "etcd or flannel not ready, exiting..." && return 1; }

  echo "Running Kubernetes" 1>&2
  if [[ -n "${REGISTRY}" ]]; then
    local REGISTRY_OPTION="--registry=${REGISTRY}"
  fi
  if [[ "${FORCED_WORKER}" == "on" ]]; then
    local FORCED_WORKER_OPT="--forced-worker"
  fi
  if [[ "${ENABLE_KEYSTONE}" == "true" ]]; then
    local ENABLE_KEYSTONE_OPT="--enable-keystone"
  fi
  /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}" ${REGISTRY_OPTION} ${FORCED_WORKER_OPT} ${ENABLE_KEYSTONE_OPT}
}

function rejoin_etcd(){
  local CONFIG_FILE="$1"
  local PROXY="$2"
  source "${CONFIG_FILE}" || return 1
  [[ -z "${PROXY}" ]] && return 1

  local IPADDR="${EX_IPADDR}" && unset EX_IPADDR
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}" && unset EX_ETCD_CLIENT_PORT
  local NODE_NAME="${EX_NODE_NAME}" && unset EX_NODE_NAME
  local IP_AND_MASK="${EX_IP_AND_MASK}" && unset EX_IP_AND_MASK
  local CLUSTER_ID="${EX_CLUSTER_ID}" && unset EX_CLUSTER_ID
  local SUBNET_ID_AND_MASK="${EX_SUBNET_ID_AND_MASK}" && unset EX_SUBNET_ID_AND_MASK
  local IPADDR_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
  local IPPORT_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\}"
  local ETCD_MEMBER_LIST="$(curl -sf http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members)"
  [[ -z "${ETCD_MEMBER_LIST}" ]] && return 1
  local ETCD_MEMBER_IP_LIST="$(echo "${ETCD_MEMBER_LIST}" \
          | jq -r '.members[].clientURLs[0]' \
          | grep -o "${IPPORT_PATTERN}")" \
          || return 1

  local EXISTED_ETCD_NODE
  local NODE
  local DISCOVERY_RESULTS
  local ETCD_NODE_LIST
  local ETCD_MEMBER_SIZE

  ETCD_MEMBER_SIZE="$(echo "${ETCD_MEMBER_LIST}" | jq '.[] | length')"

  # If this node was a etcd member, exit from the cluster
  if [[ "${ETCD_MEMBER_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]] && [[ "${ETCD_MEMBER_SIZE}" -gt "1" ]]; then
    local MEMBER_ID="$(echo "${ETCD_MEMBER_LIST}" | jq -r ".members[] | select(contains({clientURLs: [\"/${IPADDR}:\"]})) | .id")"
    test "${MEMBER_ID}" && curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members/${MEMBER_ID}" -XDELETE
    rm -rf "/var/lib/etcd/"*
  elif [[ "${ETCD_MEMBER_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
    return 1
  fi

  DISCOVERY_RESULTS="$(/go/dnssd/browsing | grep -w "NetworkID=${SUBNET_ID_AND_MASK}" | grep -w 'etcdProxy=off')"
  ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" \
                    | grep -w "clusterID=${CLUSTER_ID}" \
                    | sed -n "s/.*IPAddr=\(${IPADDR_PATTERN}\).*etcdPort=\([[:digit:]]*\).*/\1:\2/p")"

  # Get an existed etcd member
  for NODE in ${ETCD_NODE_LIST}; do
    if curl -s -m 10 "${NODE}/health" &>/dev/null; then
      EXISTED_ETCD_NODE="${NODE}"
      break
    fi
  done
  if [[ -z "${EXISTED_ETCD_NODE}" ]]; then
    echo "No etcd member available, exiting..." 1>&2
    return 1
  fi

  # Stop the etcd service in the loacl
  bash -c 'docker stop k8sup-etcd' &>/dev/null || true
  bash -c 'docker rm k8sup-etcd' &>/dev/null || true

  # Join the same etcd cluster again
  etcd_follower "${IPADDR}" "${NODE_NAME}" "${ETCD_NODE_LIST}" "${PROXY}"

  # DNS-SD
  local OLD_MDNS_PID="$(ps aux | grep '/go/dnssd/registering' | grep -v grep | awk '{print $2}')"
  [[ -n "${OLD_MDNS_PID}" ]] && kill ${OLD_MDNS_PID} && wait ${OLD_MDNS_PID} 2>/dev/null || true
  CLUSTER_ID="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/clusterid" | jq -r '.node.value')"
  /go/dnssd/registering "${NODE_NAME}" "${IP_AND_MASK}" "${ETCD_CLIENT_PORT}" "${CLUSTER_ID}" "${PROXY}" "true" &
}

function show_usage(){
  local USAGE="Usage: ${0##*/} [options...]
Options:
-n, --network=NETINFO        SubnetID/Mask or Host IP address or NIC name
                             e. g. \"192.168.11.0/24\" or \"192.168.11.1\"
                             or \"eth0\"
-c, --cluster=CLUSTER_ID     Join a specified cluster
-v, --version=VERSION        Specify k8s version (Default: 1.5.2)
    --max-etcd-members=NUM   Maximum etcd member size (Default: 3)
    --new                    Force to start a new cluster
    --restore                Try to restore etcd data and start a new cluster
    --restart                Restart etcd and k8s services
    --rejoin-etcd            Re-join the same etcd cluster
    --start-kube-svcs-only   Try to start kubernetes services (Assume etcd and flannel are ready)
    --start-etcd-only        Start etcd and flannel but don't start kubernetes services
    --worker                 Force to run as k8s worker and etcd proxy
    --debug                  Enable debug mode
-r, --registry=REGISTRY      Registry of docker image
    --enable-keystone        Enable Keystone service (Default: disabled)
                             (Default: 'quay.io/coreos' and 'gcr.io/google_containers')
-h, --help                   This help text
"

  echo "${USAGE}"
}

function get_options(){
  local PROGNAME="${0##*/}"
  local SHORTOPTS="n:c:v:r:h"
  local LONGOPTS="network:,cluster:,version:,max-etcd-members:,new,worker,debug,restore,restart,rejoin-etcd,start-kube-svcs-only,start-etcd-only,registry:,enable-keystone,help"
  local PARSED_OPTIONS=""

  PARSED_OPTIONS="$(getopt -o "${SHORTOPTS}" --long "${LONGOPTS}" -n "${PROGNAME}" -- "$@")" || exit 1
  eval set -- "${PARSED_OPTIONS}"

  # extract options and their arguments into variables.
  while true ; do
      case "$1" in
          -n|--network)
              export EX_NETWORK="$2"
              shift 2
              ;;
          -c|--cluster)
              export EX_CLUSTER_ID="$2"
              shift 2
              ;;
          -v|--version)
              export EX_K8S_VERSION="$2"
              shift 2
              ;;
             --max-etcd-members)
              export EX_MAX_ETCD_MEMBER_SIZE="$2"
              shift 2
              ;;
             --new)
              export EX_NEW_CLUSTER="true"
              shift
              ;;
             --restore)
              export EX_RESTORE_ETCD="true"
              shift
              ;;
             --restart)
              export EX_RESTART="true"
              shift
              ;;
             --rejoin-etcd)
              export EX_REJOIN_ETCD="true"
              shift
              ;;
             --start-kube-svcs-only)
              export EX_START_KUBE_SVCS_ONLY="true"
              shift
              ;;
             --start-etcd-only)
              export EX_START_ETCD_ONLY="true"
              shift
              ;;
             --debug)
              set -x
              export SHELLOPTS
              shift
              ;;
             --worker)
              export EX_PROXY="on"
              shift
              ;;
          -r|--registry)
              export EX_COREOS_REGISTRY="$2"
              export EX_K8S_REGISTRY="$2"
              shift 2
              ;;
             --enable-keystone)
              export EX_ENABLE_KEYSTONE="true"
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

  if [[ "${EX_PROXY}" != "on" ]]; then
    export EX_PROXY="off"
  fi

  if [[ -n "${EX_CLUSTER_ID}" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! '--new' can not use specified cluster ID, exiting..." 1>&2
    exit 1
  fi

  if [[ "${EX_RESTORE_ETCD}" == "true" ]]; then
    export EX_NEW_CLUSTER="true"
  fi

  if [[ "${EX_PROXY}" == "on" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either run as proxy or start a new/restored etcd cluster, exiting..." 1>&2
    exit 1
  fi

  if [[ -z "${EX_K8S_VERSION}" ]]; then
    export EX_K8S_VERSION="1.5.2"
  fi

  if [[ -z "${EX_MAX_ETCD_MEMBER_SIZE}" ]]; then
    export EX_MAX_ETCD_MEMBER_SIZE="3"
  fi

  if [[ -z "${EX_COREOS_REGISTRY}" ]] || [[ -z "${EX_K8S_REGISTRY}" ]]; then
    export EX_COREOS_REGISTRY="quay.io/coreos"
    export EX_K8S_REGISTRY="gcr.io/google_containers"
  fi
}

function main(){
  get_options "$@"

  local COREOS_REGISTRY="${EX_COREOS_REGISTRY}"
  local K8S_REGISTRY="${EX_K8S_REGISTRY}"
  export ENV_ETCD_VERSION="3.0.17"
  export ENV_FLANNELD_VERSION="0.6.2"
  export ENV_ETCD_IMAGE="${COREOS_REGISTRY}/etcd:v${ENV_ETCD_VERSION}"
  export ENV_FLANNELD_IMAGE="${COREOS_REGISTRY}/flannel:v${ENV_FLANNELD_VERSION}"

  # Set a config file
  local CONFIG_FILE="/root/.bashrc"
  local REJOIN_ETCD="${EX_REJOIN_ETCD}" && unset EX_REJOIN_ETCD
  local START_ETCD_ONLY="${EX_START_ETCD_ONLY}" && unset EX_START_KUBE_SVCS_ONLY

  local PROXY="${EX_PROXY}" && unset EX_PROXY
  # Just re-join etcd cluster only
  if [[ "${REJOIN_ETCD}" == "true" ]]; then
    rejoin_etcd "${CONFIG_FILE}" "${PROXY}"
    exit "$?"
  fi

  local START_KUBE_SVCS_ONLY="${EX_START_KUBE_SVCS_ONLY}" && unset EX_START_KUBE_SVCS_ONLY
  if [[ "${START_KUBE_SVCS_ONLY}" == "true" ]]; then
    kube_up "${CONFIG_FILE}"
    exit "$?"
  fi

  local RESTART="${EX_RESTART}" && unset EX_RESTART
  if [[ "${RESTART}" == "true" ]]; then
    /go/kube-down --stop-k8s-only
    rejoin_etcd "${CONFIG_FILE}" "${PROXY}" || true
    kube_up "${CONFIG_FILE}"
    exit "$?"
  fi

  local CLUSTER_ID="${EX_CLUSTER_ID}" && unset EX_CLUSTER_ID
  local NETWORK="${EX_NETWORK}" && unset EX_NETWORK
  [[ -z "${NETWORK}" ]] && { NETWORK="$(get_network_by_cluster_id "${CLUSTER_ID}")" || exit 1; }
  local IP_AND_MASK=""
  IP_AND_MASK="$(get_ipaddr_and_mask_from_netinfo "${NETWORK}")" || exit 1
  local IPADDR="$(echo "${IP_AND_MASK}" | cut -d '/' -f 1)"
  local NEW_CLUSTER="${EX_NEW_CLUSTER}" && unset EX_NEW_CLUSTER
  local MAX_ETCD_MEMBER_SIZE="${EX_MAX_ETCD_MEMBER_SIZE}" && unset EX_MAX_ETCD_MEMBER_SIZE
  local RESTORE_ETCD="${EX_RESTORE_ETCD}" && unset EX_RESTORE_ETCD
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local ENABLE_KEYSTONE="${EX_ENABLE_KEYSTONE}" && unset EX_ENABLE_KEYSTONE
  local ETCD_PATH="k8sup/cluster"
  local K8S_PORT="6443"
  local K8S_INSECURE_PORT="8080"
  local SUBNET_ID_AND_MASK="$(get_subnet_id_and_mask "${IP_AND_MASK}")"
  local IPADDR_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"

  bash -c 'docker stop k8sup-etcd k8sup-flannel k8sup-kubelet k8sup-certs' &>/dev/null || true
  bash -c 'docker rm k8sup-etcd k8sup-flannel k8sup-kubelet k8sup-certs' &>/dev/null || true
  bash -c 'ip link delete cni0' &>/dev/null || true

  local NODE_NAME="$(hostname)"
  local ETCD_CLIENT_PORT="2379"
  local ROLE
  echo "Starting k8sup..." 1>&2
  if [[ -d "/var/lib/etcd/member" ]] || [[ -d "/var/lib/etcd/proxy" ]]; then
    echo "Found etcd data in the local storage (/var/lib/etcd), trying to start etcd with these data." 1>&2
    etcd_creator "${IPADDR}" "${NODE_NAME}" "${CLUSTER_ID}" "${MAX_ETCD_MEMBER_SIZE}" \
      "${ETCD_CLIENT_PORT}" "${NEW_CLUSTER}" "${RESTORE_ETCD}" && ROLE="follower" || exit 1
  else
    if [[ "${NEW_CLUSTER}" != "true" ]]; then
      /go/dnssd/registering "${NODE_NAME}" "${IP_AND_MASK}" "${ETCD_CLIENT_PORT}" "${CLUSTER_ID}" "${PROXY}" "false" &
      # If do not force to start an etcd cluster, make a discovery.
      echo "Discovering etcd cluster..."
      while
        DISCOVERY_RESULTS="$(/go/dnssd/browsing | grep -w "NetworkID=${SUBNET_ID_AND_MASK}" | grep -w 'etcdProxy=off')" || true
        echo "${DISCOVERY_RESULTS}"

        # Check if the hostname is duplicate then exit
        if [[ "$(echo "${DISCOVERY_RESULTS}" \
                 | sed -n "s/.*NodeName=\([[:alnum:]_-]*\).*/\1/p" \
                 | grep -w "${NODE_NAME}" \
                 | wc -l)" -gt "1" ]]; then
          echo "Hostname is duplicate, please rename the hostname and try again, exiting..." 1>&2
          exit 1
        fi

        # If find an etcd cluster that user specified or find only one etcd cluster, join it instead of starting a new.
        local EXISTED_ETCD_NODE_LIST=""
        local EXISTED_ETCD_NODE=""
        local CLUSTER_ID_AMOUNT="$(echo "${DISCOVERY_RESULTS}" | sed -n "s/.*clusterID=\([[:alnum:]_-]*\).*/\1/p" | uniq | wc -l)"

        if [[ "${PROXY}" == "on" ]] \
           && [[ "${CLUSTER_ID_AMOUNT}" -eq "0" ]]; then
          echo "No such any existed cluster for this worker, re-discovering..." 1>&2
        fi

        if [[ -z "${CLUSTER_ID}" ]]; then
          if [[ "${CLUSTER_ID_AMOUNT}" -gt "1" ]]; then
            # I don't have clusterID and found more than one existed cluster.
            if [[ "${PROXY}" == "off" ]]; then
              CLUSTER_ID="$(uuidgen -r | tr -d '-' | cut -c1-16)"
              echo "Found multiple existed clusters, starting a new cluster using ID: ${CLUSTER_ID}..." 1>&2
              break
            else
              echo "Found more than one existed cluster, please re-run k8sup and specify Cluster ID or turn off other cluster(s) if you don't need, re-discovering..." 1>&2
              continue
            fi
          elif [[ "${CLUSTER_ID_AMOUNT}" -eq "1" ]]; then
            # I don't have clusterID and found some nodes have the same clusterID (Some nodes may have no clusterID).
            CLUSTER_ID="$(echo "${DISCOVERY_RESULTS}" | sed -n "s/.*clusterID=\([[:alnum:]_-]*\).*/\1/p" | uniq)"
            EXISTED_ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" \
                                      | grep -w "clusterID=${CLUSTER_ID}" \
                                      | sed -n "s/.*IPAddr=\(${IPADDR_PATTERN}\).*etcdPort=\([[:digit:]]*\).*/\1:\2/p")"
            EXISTED_ETCD_NODE="$(echo "${EXISTED_ETCD_NODE_LIST}" | head -n 1)"
            echo "Target etcd member: ${EXISTED_ETCD_NODE} in the existed cluster, try to join it..." 1>&2
          fi
        else
          if [[ -n "$(echo "${DISCOVERY_RESULTS}" | grep -w "etcdStarted=true" | grep -w "clusterID=${CLUSTER_ID}")" ]]; then
            # I have clusterID and an existed cluster has the same clusterID.
            EXISTED_ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" \
                                      | grep -w "etcdStarted=true" \
                                      | grep -w "clusterID=${CLUSTER_ID}" \
                                      | sed -n "s/.*IPAddr=\(${IPADDR_PATTERN}\).*etcdPort=\([[:digit:]]*\).*/\1:\2/p")"
            EXISTED_ETCD_NODE="$(echo "${EXISTED_ETCD_NODE_LIST}" | head -n 1)"
            echo "Target etcd member: ${EXISTED_ETCD_NODE} in the existed cluster, try to join it..." 1>&2
          elif [[ -n "$(echo "${DISCOVERY_RESULTS}" | grep -w "etcdStarted=false" | grep -w "clusterID=${CLUSTER_ID}")" ]]; then
            # I have clusterID and other nodes have the same, but all not started yet.
            DISCOVERY_RESULTS="$(echo "${DISCOVERY_RESULTS}" | grep -w "clusterID=${CLUSTER_ID}")"
          elif [[ "${PROXY}" == "on" ]]; then
            echo "No such any existed clusterID that you specified for this worker, re-discovering..." 1>&2
            continue
          fi
        fi
        if [[ -z "${EXISTED_ETCD_NODE}" ]]; then
          local CREATOR_NODE="$(echo "${DISCOVERY_RESULTS}" \
                                    | grep 'etcdStarted=false' \
                                    | sed -n "s/.*IPAddr=\(${IPADDR_PATTERN}\).*etcdPort=\([[:digit:]]*\).*UnixNanoTime=\([[:digit:]]*\).*/\1:\2 \3/p" \
                                    | sort -k 2,2 \
                                    | head -n 1 \
                                    | awk '{print $1}')"
          if [[ "${CREATOR_NODE}" != "${IPADDR}:${ETCD_CLIENT_PORT}" ]]; then
            EXISTED_ETCD_NODE_LIST="${CREATOR_NODE}"
            EXISTED_ETCD_NODE="$(echo "${EXISTED_ETCD_NODE_LIST}" | head -n 1)"
          fi
        fi
        [[ -z "${EXISTED_ETCD_NODE}" && "${PROXY}" == "on" ]]
      do :; done
    fi

    if [[ -n "${EXISTED_ETCD_NODE}" ]]; then
      ETCD_CLIENT_PORT="$(echo "${EXISTED_ETCD_NODE}" | cut -d ':' -f 2)"
    fi

    if [[ -z "${EXISTED_ETCD_NODE}" ]] || [[ "${NEW_CLUSTER}" == "true" ]]; then
      ROLE="creator"
      if [[ -z "${CLUSTER_ID}" ]]; then
        CLUSTER_ID="$(uuidgen -r | tr -d '-' | cut -c1-16)"
      fi
    else
      ROLE="follower"
    fi

    echo "Copy cni plugins"
    mkdir -p /etc/cni/net.d/
    cp -f /go/cni-conf/10-containernet.conf /etc/cni/net.d/
    cp -f /go/cni-conf/99-loopback.conf /etc/cni/net.d/
    mkdir -p /var/lib/cni/networks/containernet; echo "" > /var/lib/cni/networks/containernet/last_reserved_ip

    echo "Running etcd"
    if [[ "${ROLE}" == "creator" ]]; then
      etcd_creator "${IPADDR}" "${NODE_NAME}" "${CLUSTER_ID}" "${MAX_ETCD_MEMBER_SIZE}" \
        "${ETCD_CLIENT_PORT}" "${NEW_CLUSTER}" "${RESTORE_ETCD}" || exit 1
    else
      etcd_follower "${IPADDR}" "${NODE_NAME}" "${EXISTED_ETCD_NODE_LIST}" "${PROXY}" || exit 1
    fi
  fi

  until curl -sf 127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys 1>/dev/null 2>&1; do
    echo "Waiting for etcd ready..."
    sleep 1
  done

  wait_etcd_cluster_healthy "${ETCD_CLIENT_PORT}"

  # DNS-SD
  local OLD_MDNS_PID="$(ps aux | grep '/go/dnssd/registering' | grep -v grep | awk '{print $2}')"
  [[ -n "${OLD_MDNS_PID}" ]] && kill ${OLD_MDNS_PID} && wait ${OLD_MDNS_PID} 2>/dev/null || true
  [[ -z "${CLUSTER_ID}" ]] && CLUSTER_ID="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${ETCD_PATH}/clusterid" | jq -r '.node.value')"
  echo -e "etcd CLUSTER_ID: \033[1;31m${CLUSTER_ID}\033[0m"
  /go/dnssd/registering "${NODE_NAME}" "${IP_AND_MASK}" "${ETCD_CLIENT_PORT}" "${CLUSTER_ID}" "${PROXY}" "true" &

  echo "Running flanneld"
  flanneld "${IPADDR}" "${ETCD_CLIENT_PORT}" "${ROLE}"

  # Write configure to file
  echo "export EX_IPADDR=${IPADDR}" >> "${CONFIG_FILE}"
  echo "export EX_ETCD_CLIENT_PORT=${ETCD_CLIENT_PORT}" >> "${CONFIG_FILE}"
  echo "export EX_FORCED_WORKER=${PROXY}" >> "${CONFIG_FILE}"
  echo "export EX_K8S_VERSION=${K8S_VERSION}" >> "${CONFIG_FILE}"
  echo "export EX_K8S_PORT=${K8S_PORT}" >> "${CONFIG_FILE}"
  echo "export EX_K8S_INSECURE_PORT=${K8S_INSECURE_PORT}" >> "${CONFIG_FILE}"
  echo "export EX_NODE_NAME=${NODE_NAME}" >> "${CONFIG_FILE}"
  echo "export EX_IP_AND_MASK=${IP_AND_MASK}" >> "${CONFIG_FILE}"
  echo "export EX_REGISTRY=${K8S_REGISTRY}" >> "${CONFIG_FILE}"
  echo "export EX_CLUSTER_ID=${CLUSTER_ID}" >> "${CONFIG_FILE}"
  echo "export EX_SUBNET_ID_AND_MASK=${SUBNET_ID_AND_MASK}" >> "${CONFIG_FILE}"
  echo "export EX_START_ETCD_ONLY=${START_ETCD_ONLY}" >> "${CONFIG_FILE}"
  echo "export EX_ENABLE_KEYSTONE=${ENABLE_KEYSTONE}" >> "${CONFIG_FILE}"
  echo "export EX_HYPERKUBE_IMAGE=${K8S_REGISTRY}/hyperkube-amd64:v${K8S_VERSION}" >> "${CONFIG_FILE}"

  if [[ "${START_ETCD_ONLY}" != "true" ]]; then
    kube_up "${CONFIG_FILE}"
    echo "Kubernetes started, hold..." 1>&2
  else
    echo "etcd started, hold..." 1>&2
  fi

  tail -f /dev/null
}

main "$@"
