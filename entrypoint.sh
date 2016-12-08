#!/bin/bash
set -e

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
  local MAX_ETCD_MEMBER_SIZE="$3"
  local CLIENT_PORT="$4"
  local NEW_CLUSTER="$5"
  local RESTORE_ETCD="$6"
  local PEER_PORT="2380"
  local ETCD_PATH="k8sup/cluster"

  if [[ "${RESTORE_ETCD}" == "true" ]]; then
    local RESTORE_CMD="--force-new-cluster=true"
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
      --proxy off

  local TIMEOUT="30"
  local COUNTER="0"
  echo -n "Waiting for etcd ready" 1>&2
  until [[ "${COUNTER}" -ge "${TIMEOUT}" ]] || curl -sf -m 1 127.0.0.1:${CLIENT_PORT}/v2/keys &>/dev/null; do
    echo -n "." 1>&2
    ((COUNTER++))
    sleep 1
  done
  echo 1>&2

  if [[ "${COUNTER}" -ge "${TIMEOUT}" ]]; then
    echo "Could not start etcd with etcd data in the local storage, you may need to use '--restore' or remove these data, exiting..." 1>&2
    sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
    sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true
    return 1
  else
    curl -sf -m 5 "127.0.0.1:${CLIENT_PORT}/v2/keys/${ETCD_PATH}/max_etcd_member_size" -XPUT -d value="${MAX_ETCD_MEMBER_SIZE}" 1>&2
    return "$?"
  fi
}

function etcd_follower(){
  local IPADDR="$1"
  local ETCD_NAME="$2"
  local ETCD_NODE_LIST="$3"
  local ETCD_NODE
  local CLIENT_PORT
  local PROXY="$4"
  local PEER_PORT="2380"
  local ETCD_PATH="k8sup/cluster"
  local ETCD_EXISTED_MEMBER_SIZE
  local ETCD_NODE_LIST
  local NODE

  # Get an existed etcd member
  for NODE in ${ETCD_NODE_LIST}; do
    if curl -s -m 10 "${NODE}/health" &>/dev/null; then
      ETCD_NODE="$(echo "${NODE}" | cut -d ':' -f 1)"
      CLIENT_PORT="$(echo "${NODE}" | cut -d ':' -f 2)"
      break
    fi
  done
  if [[ -z "${ETCD_NODE}" || -z "${CLIENT_PORT}" ]]; then
    echo "No etcd member available, exiting..." 1>&2
    exit 1
  fi

  # Prevent the cap of etcd member size less then 3
  local MAX_ETCD_MEMBER_SIZE="$(curl -s --retry 10 "${ETCD_NODE}:${CLIENT_PORT}/v2/keys/${ETCD_PATH}/max_etcd_member_size" 2>/dev/null \
                                | jq -r '.node.value')"
  if [[ "${MAX_ETCD_MEMBER_SIZE}" -lt "3" ]]; then
    MAX_ETCD_MEMBER_SIZE="3"
    curl -s "${ETCD_NODE}:${CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
      -XPUT -d value="${MAX_ETCD_MEMBER_SIZE}" 1>&2
  fi

  docker pull "${ENV_ETCD_IMAGE}" 1>&2

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
      --proxy "${PROXY}"


  if [[ "${ALREADY_MEMBER}" != "true" ]] && [[ "${PROXY}" == "off" ]]; then
    # Unlock and release the privilege for joining etcd cluster
    until curl -sf "${LOCKER_URL}?prevValue=${IPADDR}" -XDELETE 1>&2; do
        sleep 1
    done
  fi
}

function wait_etcd_cluster_healthy(){
  local ETCD_CID="$1"
  local ETCD_CLIENT_PORT="$2"

  echo "Waiting until etcd cluster is healthy..." 1>&2
  until [[ \
    "$(docker exec \
       "${ETCD_CID}" \
       /usr/local/bin/etcdctl \
       --endpoints http://127.0.0.1:${ETCD_CLIENT_PORT} \
       cluster-health \
        | grep 'cluster is' | awk '{print $3}')" == "healthy" ]]; do
    sleep 1
  done

}

function flanneld(){
  local IPADDR="$1"
  local ETCD_CID="$2"
  local ETCD_CLIENT_PORT="$3"
  local ROLE="$4"

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
      "${ETCD_CID}" \
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

# Convert CIDR to submask format. e.g. 23 => 255.255.254.0
function cidr2mask(){
   # Number of args to shift, 255..255, first non-255 byte, zeroes
   set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
   [ $1 -gt 1 ] && shift $1 || shift
   echo ${1-0}.${2-0}.${3-0}.${4-0}
}

# Convert IP address from decimal to heximal. e.g. 192.168.1.200 => 0xC0A801C8
function addr2hex(){
  local IPADDR="$1"
  echo "0x$(printf '%02X' ${IPADDR//./ } ; echo)"
}

# Convert IP/Mask to SubnetID/Mask. e.g. 192.168.1.200/24 => 192.168.0.0/23
function get_subnet_id_and_mask(){
  local ADDR_AND_MASK="$1"
  local IPMASK_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}"
  echo "${ADDR_AND_MASK}" | grep -o "${IPMASK_PATTERN}" &>/dev/null || { echo "Wrong Address/Mask pattern, exiting..." 1>&2; exit 1; }

  local ADDR="$(echo "${ADDR_AND_MASK}" | cut -d '/' -f 1)"
  local MASK="$(echo "${ADDR_AND_MASK}" | cut -d '/' -f 2)"

  local HEX_ADDR=$(addr2hex "${ADDR}")
  local HEX_MASK=$(addr2hex $(cidr2mask "${MASK}"))
  local HEX_NETWORK=$(printf '%02X' $((${HEX_ADDR} & ${HEX_MASK})))

  local NETWORK=$(printf '%d.' 0x${HEX_NETWORK:0:2} 0x${HEX_NETWORK:2:2} 0x${HEX_NETWORK:4:2} 0x${HEX_NETWORK:6:2})
  SUBNET_ID="${NETWORK:0:-1}"
  echo "${SUBNET_ID}/${MASK}"
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

  # If NETINFO is IP_AND_MASK
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

function rejoin_etcd(){
  local CONFIG_FILE="$1"
  local PROXY="$2"
  source "${CONFIG_FILE}" || exit 1
  [[ -z "${PROXY}" ]] && exit 1

  local IPADDR="${EX_IPADDR}" && unset EX_IPADDR
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}" && unset EX_ETCD_CLIENT_PORT
  local K8S_PORT="${EX_K8S_PORT}" && unset EX_K8S_PORT
  local NODE_NAME="${EX_NODE_NAME}" && unset EX_NODE_NAME
  local IP_AND_MASK="${EX_IP_AND_MASK}" && unset EX_IP_AND_MASK
  local CLUSTER_ID="${EX_CLUSTER_ID}" && unset EX_CLUSTER_ID
  local SUBNET_ID_AND_MASK="${EX_SUBNET_ID_AND_MASK}" && unset EX_SUBNET_ID_AND_MASK
  local IPPORT_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\}"
  local ETCD_MEMBER_LIST="$(curl -s http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members)"
  local ETCD_MEMBER_IP_LIST="$(echo "${ETCD_MEMBER_LIST}" \
          | jq -r '.members[].clientURLs[0]' \
          | grep -o "${IPPORT_PATTERN}")" \
          || exit 1

  local EXISTED_ETCD_NODE
  local NODE
  local DISCOVERY_RESULTS
  local ETCD_NODE_LIST

  # If this node was a etcd member, exit from the cluster
  if [[ "${ETCD_MEMBER_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
    local MEMBER_ID="$(echo "${ETCD_MEMBER_LIST}" | jq -r ".members[] | select(contains({clientURLs: [\"/${IPADDR}:\"]})) | .id")"
    test "${MEMBER_ID}" && curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members/${MEMBER_ID}" -XDELETE
    docker stop k8sup-etcd
    docker rm k8sup-etcd
    rm -rf "/var/lib/etcd/"*
  fi

  DISCOVERY_RESULTS="<nil>"
  until [[ -z "$(echo "${DISCOVERY_RESULTS}" | grep '<nil>')" ]]; do
    DISCOVERY_RESULTS="$(go run /go/dnssd/browsing.go | grep -w "NetworkID=${SUBNET_ID_AND_MASK}")"
  done
  ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" | grep -w "clusterID=${CLUSTER_ID}" | awk '{print $2}')"

  # Get an existed etcd member
  for NODE in ${ETCD_NODE_LIST}; do
    if curl -s -m 10 "${NODE}/health"; then
#      ETCD_NODE_LIST="$(echo "${ETCD_NODE_LIST}" | sed /^${NODE}$/d)"
      EXISTED_ETCD_NODE="${NODE}"
      break
    fi
  done
  if [[ -z "${EXISTED_ETCD_NODE}" ]]; then
    echo "No etcd member available, exiting..." 1>&2
    exit 1
  fi

  # Stop the etcd service in the loacl
  sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true

  # Join the same etcd cluster again
  etcd_follower "${IPADDR}" "${NODE_NAME}" "${ETCD_NODE_LIST}" "${PROXY}"

  until curl -sf 127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys 1>/dev/null 2>&1; do
    echo "Waiting for etcd ready..."
    sleep 1
  done

  # DNS-SD
  killall "registering.go" || true
  local CLUSTER_ID="$(curl 127.0.0.1:${ETCD_CLIENT_PORT}/v2/members -vv 2>&1 \
    | grep 'X-Etcd-Cluster-Id' \
    | sed -n "s/.*: \(.*\)$/\1/p" | tr -d '\r')"
  bash -c "go run /go/dnssd/registering.go \"${NODE_NAME}\" \"${IP_AND_MASK}\" \"${ETCD_CLIENT_PORT}\" \"${CLUSTER_ID}\"" &
}

function show_usage(){
  local USAGE="Usage: ${0##*/} [options...]
Options:
-n, --network=NETINFO        SubnetID/Mask or Host IP address or NIC name
                             e. g. \"192.168.11.0/24\" or \"192.168.11.1\"
                             or \"eth0\" (Required option)
-c, --cluster=CLUSTER_ID     Join a specified cluster
-v, --version=VERSION        Specify k8s version (Default: 1.4.6)
    --max-etcd-members=NUM   Maximum etcd member size
    --new                    Force to start a new cluster
    --restore                Try to restore etcd data and start a new cluster
    --rejoin-etcd            Re-join the same etcd cluster
    --worker                 Force to run as k8s worker and etcd proxy
    --debug                  Enable debug mode
-r, --registry=REGISTRY      Registry of docker image
                             (Default: 'quay.io/coreos' and 'gcr.io/google_containers')
-h, --help                   This help text
"

  echo "${USAGE}"
}

function get_options(){
  local PROGNAME="${0##*/}"
  local SHORTOPTS="n:c:v:r:h"
  local LONGOPTS="network:,cluster:,version:,max-etcd-members:,new,worker,debug,restore,rejoin-etcd,registry:,help"
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
             --rejoin-etcd)
              export EX_REJOIN_ETCD="true"
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

  if [[ "${EX_RESTORE_ETCD}" == "true" ]]; then
    export EX_NEW_CLUSTER="true"
  fi

  if [[ -z "${EX_NETWORK}" ]] && [[ -z "${EX_REJOIN_ETCD}" ]]; then
    echo "--network (-n) is required, exiting..." 1>&2
    exit 1
  fi

  if [[ -n "${EX_CLUSTER_ID}" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either join a existed etcd cluster or start a new/restored etcd cluster, exiting..." 1>&2
    exit 1
  fi

  if [[ "${EX_PROXY}" == "on" ]] && [[ "${EX_NEW_CLUSTER}" == "true" ]]; then
    echo "Error! Either run as proxy or start a new/restored etcd cluster, exiting..." 1>&2
    exit 1
  fi

  if [[ -z "${EX_K8S_VERSION}" ]]; then
    export EX_K8S_VERSION="1.4.6"
  fi

  if [[ -z "${EX_MAX_ETCD_MEMBER_SIZE}" ]]; then
    export EX_MAX_ETCD_MEMBER_SIZE="5"
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
  export ENV_ETCD_VERSION="3.0.15"
  export ENV_FLANNELD_VERSION="0.6.2"
#  export ENV_K8S_VERSION="1.4.6"
  export ENV_ETCD_IMAGE="${COREOS_REGISTRY}/etcd:v${ENV_ETCD_VERSION}"
  export ENV_FLANNELD_IMAGE="${COREOS_REGISTRY}/flannel:v${ENV_FLANNELD_VERSION}"
#  export ENV_HYPERKUBE_IMAGE="gcr.io/google_containers/hyperkube-amd64:v${ENV_K8S_VERSION}"

  # Set a config file
  local CONFIG_FILE="/root/.bashrc"
  local REJOIN_ETCD="${EX_REJOIN_ETCD}" && unset EX_REJOIN_ETCD

  local PROXY="${EX_PROXY}" && unset EX_PROXY
  # Just re-join etcd cluster only
  if [[ "${REJOIN_ETCD}" == "true" ]]; then
    rejoin_etcd "${CONFIG_FILE}" "${PROXY}"
    exit 0
  fi

  local IP_AND_MASK=""
  IP_AND_MASK="$(get_ipaddr_and_mask_from_netinfo "${EX_NETWORK}")" && unset EX_NETWORK || exit 1
  local IPADDR="$(echo "${IP_AND_MASK}" | cut -d '/' -f 1)"
  local CLUSTER_ID="${EX_CLUSTER_ID}" && unset EX_CLUSTER_ID
  local NEW_CLUSTER="${EX_NEW_CLUSTER}" && unset EX_NEW_CLUSTER
  local MAX_ETCD_MEMBER_SIZE="${EX_MAX_ETCD_MEMBER_SIZE}" && unset EX_MAX_ETCD_MEMBER_SIZE
  local RESTORE_ETCD="${EX_RESTORE_ETCD}" && unset EX_RESTORE_ETCD
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local K8S_PORT="8080"
  local SUBNET_ID_AND_MASK="$(get_subnet_id_and_mask "${IP_AND_MASK}")"
  local DISCOVERY_RESULTS

  sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-kubelet' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-kubelet' >/dev/null 2>&1 || true
  sh -c 'ip link delete cni0' >/dev/null 2>&1 || true

  local NODE_NAME="node-$(uuidgen -r | cut -c1-6)"
  local ETCD_CLIENT_PORT="2379"
  local ETCD_CID
  local ROLE
  if [[ -d "/var/lib/etcd/member" ]]; then
    echo "Found etcd data in the local storage (/var/lib/etcd), trying to start etcd with these data..." 1>&2
    ETCD_CID=$(etcd_creator "${IPADDR}" "${NODE_NAME}" "${MAX_ETCD_MEMBER_SIZE}" \
             "${ETCD_CLIENT_PORT}" "${NEW_CLUSTER}" "${RESTORE_ETCD}") && ROLE="follower" || exit 1
  fi

  if [[ "${ROLE}" != "follower" ]]; then
    if [[ "${NEW_CLUSTER}" != "true" ]]; then
      # If do not force to start an etcd cluster, make a discovery.
      echo "Discovering etcd cluster..."
      DISCOVERY_RESULTS="<nil>"
      until [[ -z "$(echo "${DISCOVERY_RESULTS}" | grep '<nil>')" ]]; do
        DISCOVERY_RESULTS="$(go run /go/dnssd/browsing.go | grep -w "NetworkID=${SUBNET_ID_AND_MASK}")"
      done
      echo "${DISCOVERY_RESULTS}"

      # If find an etcd cluster that user specified or find only one etcd cluster, join it instead of starting a new.
      local EXISTED_ETCD_NODE_LIST=""
      local EXISTED_ETCD_NODE=""
      if [[ -n "${CLUSTER_ID}" ]]; then
        EXISTED_ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" | grep -w "clusterID=${CLUSTER_ID}" | awk '{print $2}')"
        EXISTED_ETCD_NODE="$(echo "${EXISTED_ETCD_NODE_LIST}" | head -n 1)"
        if [[ -z "${EXISTED_ETCD_NODE}" ]]; then
          echo "No such the etcd cluster that user specified, exiting..." 1>&2
          exit 1
        fi
      elif [[ "$(echo "${DISCOVERY_RESULTS}" | sed -n "s/.*clusterID=\([[:alnum:]]*\).*/\1/p" | uniq | wc -l)" -eq "1" ]]; then
        EXISTED_ETCD_NODE="$(echo "${DISCOVERY_RESULTS}" | head -n 1 | awk '{print $2}')"
      fi
      echo "etcd member: ${EXISTED_ETCD_NODE}"
    fi

    if [[ -n "${EXISTED_ETCD_NODE}" ]]; then
      ETCD_CLIENT_PORT="$(echo "${EXISTED_ETCD_NODE}" | cut -d ':' -f 2)"
    fi

    if [[ -z "${EXISTED_ETCD_NODE}" ]] && [[ "${PROXY}" == "on" ]]; then
      echo "Proxy mode needs a cluster to join, exiting..." 1>&2
      exit 1
    fi

    if [[ -z "${EXISTED_ETCD_NODE}" ]] || [[ "${NEW_CLUSTER}" == "true" ]]; then
      ROLE="creator"
    else
      ROLE="follower"
    fi

    echo "Copy cni plugins"
#   cp -rf bin /opt/cni
    mkdir -p /etc/cni/net.d/
    cp -f /go/cni-conf/10-containernet.conf /etc/cni/net.d/
    cp -f /go/cni-conf/99-loopback.conf /etc/cni/net.d/
    mkdir -p /var/lib/cni/networks/containernet; echo "" > /var/lib/cni/networks/containernet/last_reserved_ip

    echo "Running etcd"
    if [[ "${ROLE}" == "creator" ]]; then
      ETCD_CID=$(etcd_creator "${IPADDR}" "${NODE_NAME}" "${MAX_ETCD_MEMBER_SIZE}" \
               "${ETCD_CLIENT_PORT}" "${NEW_CLUSTER}" "${RESTORE_ETCD}") || exit 1
    else
      ETCD_CID=$(etcd_follower "${IPADDR}" "${NODE_NAME}" "${EXISTED_ETCD_NODE_LIST}" "${PROXY}") || exit 1
    fi
  fi

  until curl -sf 127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys 1>/dev/null 2>&1; do
    echo "Waiting for etcd ready..."
    sleep 1
  done

  # DNS-SD
  local CLUSTER_ID="$(curl 127.0.0.1:${ETCD_CLIENT_PORT}/v2/members -vv 2>&1 | grep 'X-Etcd-Cluster-Id' | sed -n "s/.*: \(.*\)$/\1/p" | tr -d '\r')"
  echo -e "etcd CLUSTER_ID: \033[1;31m${CLUSTER_ID}\033[0m"
  bash -c "go run /go/dnssd/registering.go \"${NODE_NAME}\" \"${IP_AND_MASK}\" \"${ETCD_CLIENT_PORT}\" \"${CLUSTER_ID}\"" &

  wait_etcd_cluster_healthy "${ETCD_CID}" "${ETCD_CLIENT_PORT}"

  echo "Running flanneld"
  flanneld "${IPADDR}" "${ETCD_CID}" "${ETCD_CLIENT_PORT}" "${ROLE}"

  # Write configure to file
  echo "export EX_IPADDR=${IPADDR}" >> "${CONFIG_FILE}"
  echo "export EX_ETCD_CLIENT_PORT=${ETCD_CLIENT_PORT}" >> "${CONFIG_FILE}"
  echo "export EX_K8S_VERSION=${K8S_VERSION}" >> "${CONFIG_FILE}"
  echo "export EX_K8S_PORT=${K8S_PORT}" >> "${CONFIG_FILE}"
  echo "export EX_NODE_NAME=${NODE_NAME}" >> "${CONFIG_FILE}"
  echo "export EX_IP_AND_MASK=${IP_AND_MASK}" >> "${CONFIG_FILE}"
  echo "export EX_REGISTRY=${K8S_REGISTRY}" >> "${CONFIG_FILE}"
  echo "export EX_CLUSTER_ID=${CLUSTER_ID}" >> "${CONFIG_FILE}"
  echo "export EX_SUBNET_ID_AND_MASK=${SUBNET_ID_AND_MASK}" >> "${CONFIG_FILE}"

  # echo "Running Kubernetes"
  if [[ -n "${K8S_REGISTRY}" ]]; then
    local REGISTRY_OPTION="--registry=${K8S_REGISTRY}"
  fi
  if [[ "${PROXY}" == "on" ]]; then
    local FORCED_WORKER_OPT="--forced-worker"
  fi
  /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}" ${REGISTRY_OPTION} ${FORCED_WORKER_OPT}

  echo "Kubernetes started, hold..." 1>&2
  tail -f /dev/null
}

main "$@"
