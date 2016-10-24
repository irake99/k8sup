#!/bin/bash

function main(){
  source "/root/.bashrc" || exit 1
  local IPADDR="${EX_IPADDR}"
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}"
  local K8S_VERSION="${EX_K8S_VERSION}"

  local MEMBER_CLIENT_ADDR_LIST
  local MEMBER_SIZE
  local MEMBER
  local MEMBER_DISCONNECTED
  local MEMBER_FAILED
  local MEMBER_REMOVED
  local MAX_ETCD_MEMBER_SIZE
  local HEALTH_CHECK_INTERVAL="20"
  local UNHEALTH_COUNT="0"
  local UNHEALTH_COUNT_THRESHOLD="3"
  local IP_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
  local LOCKER_ETCD_KEY="k8sup/cluster/etcd-rejoining"
  local MEMBER_REMOVED_KEY="k8sup/cluster/member-removed"
  local ETCD_MEMBER_SIZE_STATUS
  local ETCD_PROXY

  echo "Running etcd-maintainer.sh ..."

  while true; do

    # Monitoring etcd member size and check if it match the max etcd member size
    MAX_ETCD_MEMBER_SIZE="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
                          | jq -r '.node.value')"
    MEMBER_CLIENT_ADDR_LIST="$(curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members" | jq -r ".members[].clientURLs[0]")"
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
    MEMBER_SIZE="$(echo "${MEMBER_CLIENT_ADDR_LIST}" | wc -l)"
    if [[ "${MEMBER_SIZE}" -eq "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      ETCD_MEMBER_SIZE_STATUS="equal"
    elif [[ "${MEMBER_SIZE}" -lt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      ETCD_MEMBER_SIZE_STATUS="lesser"
    elif [[ "${MEMBER_SIZE}" -gt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      local ETCD_MEMBER_SIZE_STATUS="greater"
    fi

    # Get this node is etcd member or proxy
    if [[ "${MEMBER_CLIENT_ADDR_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
      ETCD_PROXY="off"
    else
      ETCD_PROXY="on"
    fi

    # If I am already a member and cluster needs more member then do nothing, vice versa.
    if [[ "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "off" ]] \
       || [[ "${ETCD_MEMBER_SIZE_STATUS}" == "greater" && "${ETCD_PROXY}" == "on" ]]; then
      sleep 60
      continue
    fi

    # Monitoring all etcd members and try to get one of the failed member
    for MEMBER in ${MEMBER_CLIENT_ADDR_LIST}; do
      if ! curl -s -m 3 "${MEMBER}/health" &>/dev/null; then
        MEMBER_DISCONNECTED="${MEMBER_DISCONNECTED}"$'\n'"${MEMBER}"
      fi
    done
    MEMBER_FAILED="$(echo "${MEMBER_DISCONNECTED}" \
     | grep -v '^$' \
     | sort \
     | uniq -c \
     | awk "\$1>=${UNHEALTH_COUNT_THRESHOLD}{print \$2}" | head -n 1 | grep -o "${IP_PATTERN}")"

    # If a failed member existing or member size does not match the cap,
    # try to adjust the member size by turns this node to member or proxy,
    # but only one node can do this at the same time.
    if [[ -z "${MEMBER_FAILED}" ]] && [[ "${ETCD_MEMBER_SIZE_STATUS}" == "equal" ]]; then
      sleep 60
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

        # Stop local k8s service
        /go/kube-down --stop-k8s-only
        # Re-join etcd cluster
        /go/entrypoint.sh --rejoin-etcd
        # Start local k8s service
        /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}"

        # Unlock
        until curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevValue=${IPADDR}" \
          -XDELETE 1>&2; do
            sleep 1
        done
      else
        # If this node still is etcd proxy, remove the failed member in the 'MEMBER_DISCONNECTED' list
        # that has been replaced, and continue to monitoring whole etcd cluster
        until curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}"; do
          MEMBER_REMOVED="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}")"
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
