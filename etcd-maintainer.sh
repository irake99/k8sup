#!/bin/bash

function get_alive_etcd_member_size(){
  local MEMBER_LIST="$1"
  local MEMBER_CLIENT_ADDR_LIST="$(echo "${MEMBER_LIST}" | jq -r ".members[].clientURLs[0]")"
  local ALIVE_ETCD_MEMBER_SIZE="0"
  local MEMBER

  for MEMBER in ${MEMBER_CLIENT_ADDR_LIST}; do
    if curl -s -m 3 "${MEMBER}/health" &>/dev/null; then
      ((ALIVE_ETCD_MEMBER_SIZE++))
    fi
  done
  echo "${ALIVE_ETCD_MEMBER_SIZE}"
}

function main(){
  source "/root/.bashrc" || exit 1
  local IPADDR="${EX_IPADDR}" && unset EX_IPADDR
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}" && unset EX_ETCD_CLIENT_PORT
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local CLUSTER_ID="${EX_CLUSTER_ID}" && unset EX_CLUSTER_ID
  local SUBNET_ID_AND_MASK="${EX_SUBNET_ID_AND_MASK}" && unset EX_SUBNET_ID_AND_MASK

  local MEMBER_LIST
  local MEMBER_CLIENT_ADDR_LIST
  local MEMBER_SIZE
  local MEMBER
  local MEMBER_DISCONNECTED
  local MEMBER_FAILED
  local MEMBER_REMOVED
  local MAX_ETCD_MEMBER_SIZE
  local HEALTH_CHECK_INTERVAL="60"
  local UNHEALTH_COUNT="0"
  local UNHEALTH_COUNT_THRESHOLD="3"
  local IPPORT_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\}"
  local LOCKER_ETCD_KEY="k8sup/cluster/etcd-rejoining"
  local MEMBER_REMOVED_KEY="k8sup/cluster/member-removed"
  local ETCD_MEMBER_SIZE_STATUS
  local ETCD_PROXY
  local DISCOVERY_RESULTS
  local ETCD_NODE_LIST
  local PROXY_OPT

  echo "Running etcd-maintainer.sh ..."

  while true; do

    # Monitoring etcd member size and check if it match the max etcd member size
    MAX_ETCD_MEMBER_SIZE="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
                          | jq -r '.node.value')"
    MEMBER_LIST="$(curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members")"
    MEMBER_CLIENT_ADDR_LIST="$(echo "${MEMBER_LIST}" | jq -r ".members[].clientURLs[0]" | grep -o "${IPPORT_PATTERN}")"
    if [[ -z "${MAX_ETCD_MEMBER_SIZE}" ]] || [[ -z "${MEMBER_CLIENT_ADDR_LIST}" ]]; then
      echo "Getting max etcd member size or member list error, exiting..." 1>&2
      exit
    fi
    if [[ "${MAX_ETCD_MEMBER_SIZE}" -lt "3" ]]; then
      # Prevent the cap of etcd member size less then 3
      MAX_ETCD_MEMBER_SIZE="3"
      curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
        -XPUT -d value="${MAX_ETCD_MEMBER_SIZE}" 1>&2
    fi
    MEMBER_SIZE="$(get_alive_etcd_member_size "${MEMBER_LIST}")"
    if [[ "${MEMBER_SIZE}" -eq "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      ETCD_MEMBER_SIZE_STATUS="equal"
    elif [[ "${MEMBER_SIZE}" -lt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      ETCD_MEMBER_SIZE_STATUS="lesser"
    elif [[ "${MEMBER_SIZE}" -gt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      local ETCD_MEMBER_SIZE_STATUS="greater"
    fi

    DISCOVERY_RESULTS="<nil>"
    until [[ -z "$(echo "${DISCOVERY_RESULTS}" | grep '<nil>')" ]]; do
      DISCOVERY_RESULTS="$(go run /go/dnssd/browsing.go | grep -w "NetworkID=${SUBNET_ID_AND_MASK}")"
    done
    ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" | grep -w "clusterID=${CLUSTER_ID}" | awk '{print $2}')"
    ETCD_NODE_SIZE="$(echo "${ETCD_NODE_LIST}" | wc -l)"

    if [[ "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" \
       && "$((${MEMBER_SIZE} % 2))" == "0" \
       && "${MEMBER_SIZE}" -eq "${ETCD_NODE_SIZE}" ]]; then
      PROXY_OPT="--proxy"
    else
      PROXY_OPT=""
    fi

    # Get this node is etcd member or proxy
    if [[ "${MEMBER_CLIENT_ADDR_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
      ETCD_PROXY="off"
    else
      ETCD_PROXY="on"
    fi

    # Monitoring all etcd members and try to get one of the failed member
    for MEMBER in ${MEMBER_DISCONNECTED}; do
      if [[ -z "$(echo "${MEMBER_DISCONNECTED}" | grep -w "${MEMBER}")" ]]; then
        MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER}/d)"
      fi
    done
    for MEMBER in ${MEMBER_CLIENT_ADDR_LIST}; do
      if ! curl -s -m 3 "${MEMBER}/health" &>/dev/null; then
        MEMBER_DISCONNECTED="${MEMBER_DISCONNECTED}"$'\n'"${MEMBER}"
      else
        MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER}/d)"
      fi
    done
    MEMBER_FAILED="$(echo "${MEMBER_DISCONNECTED}" \
     | grep -v '^$' \
     | sort \
     | uniq -c \
     | awk "\$1>=${UNHEALTH_COUNT_THRESHOLD}{print \$2}" | head -n 1 | cut -d ':' -f 1)"

    # If a failed member existing or member size does not match the cap,
    # try to adjust the member size by turns this node to member or proxy,
    # but only one node can do this at the same time.

    if [[ -z "${MEMBER_FAILED}" && -z "${PROXY_OPT}" && "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "off" ]] \
       || [[ -z "${MEMBER_FAILED}" && -z "${PROXY_OPT}" && "${ETCD_MEMBER_SIZE_STATUS}" == "greater" && "${ETCD_PROXY}" == "on" ]] \
       || [[ -z "${MEMBER_FAILED}" && -z "${PROXY_OPT}" && "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "on" \
          && "$((${MEMBER_SIZE} % 2))" == "1" \
          && "$((${ETCD_NODE_SIZE} - ${MEMBER_SIZE}))" -le "1" ]]; then
      sleep "${HEALTH_CHECK_INTERVAL}"
      continue
    else
      # Lock
      if curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevExist=false" \
        -XPUT -d value="${IPADDR}" 1>&2; then

        if [[ -n "${MEMBER_FAILED}" ]]; then
          # Notify other node the failed member which will be replaced
          curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}" \
            -XPUT -d value="${MEMBER_FAILED}"

          # Set the remote failed etcd member to exit the etcd cluster
          /go/kube-down --exit-remote-etcd="${MEMBER_FAILED}"

          # Remove the failed member that has been repaced from the list
          MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER_FAILED}/d)"
        else
          # Notify other node that there is no failed member to be replaced
          curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}" \
            -XPUT -d value="NULL" 1>&2
        fi

        if [[ -z "${MEMBER_DISCONNECTED}" ]]; then
          if [[ "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "on" ]] \
             || [[ "${ETCD_MEMBER_SIZE_STATUS}" == "greater" && "${ETCD_PROXY}" == "off" ]] \
             || [[ -n "${PROXY_OPT}" ]]; then
            # Re-join etcd cluster
            /go/entrypoint.sh --rejoin-etcd ${PROXY_OPT}
          fi
        fi

        # Unlock
        until curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevValue=${IPADDR}" \
          -XDELETE 1>&2; do
            sleep 1
        done
      else
        # If this node still is etcd proxy, remove the failed member in the 'MEMBER_DISCONNECTED' list
        # that has been replaced, and continue to monitoring whole etcd cluster
        until curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}"; do
          MEMBER_REMOVED="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}" | jq -r .node.value)"
          sleep 1
        done
        if [[ "${MEMBER_REMOVED}" != "NULL" ]]; then
          # Remove the failed member that has been repaced from the list
          MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER_REMOVED}/d)"
        fi
      fi
    fi

    sleep "${HEALTH_CHECK_INTERVAL}"
  done
}

main "$@"
