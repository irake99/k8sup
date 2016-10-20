#!/bin/bash

function rejoin_etcd(){
  /go/entrypoint.sh --rejoin-etcd
}

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
  local HEALTH_CHECK_INTERVAL="15"
  local UNHEALTH_COUNT="0"
  local UNHEALTH_COUNT_THRESHOLD="3"
  local IP_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
  local LOCKER_ETCD_KEY="k8sup/cluster/etcd-rejoining"
  local MEMBER_REMOVED_KEY="k8sup/cluster/member-removed"
  local ETCD_PROXY
  while true; do

    # If I am already etcd member, do nothing...
    local MEMBER_LIST="$(curl -s http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members)"
    if [[ "${MEMBER_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
      ETCD_PROXY="off"
      sleep 60
      continue
    else
      ETCD_PROXY="on"
    fi

    # If I am a etcd proxy...
    # Monitoring all etcd members and try to get one of the failed member
    MAX_ETCD_MEMBER_SIZE="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
                          | jq -r '.node.value')"
    MEMBER_CLIENT_ADDR_LIST="$(curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members" | jq -r ".members[].clientURLs[0]")"
    if [[ -z "${MAX_ETCD_MEMBER_SIZE}" ]] || [[ -z "${MEMBER_CLIENT_ADDR_LIST}" ]]; then
      echo "Getting max etcd member size and member list error, exiting..." 1>&2
      exit
    fi
    MEMBER_SIZE="$(echo "${MEMBER_CLIENT_ADDR_LIST}" | wc -l)"
    if [[ "${MEMBER_SIZE}" -lt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      local ETCD_CLUSTER_IS_NOT_FULL="true"
    else
      local ETCD_CLUSTER_IS_NOT_FULL="false"
    fi
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

    # If a failed member existing, try to turn this proxy node as a etcd member,
    # but only one proxy node can do this at the same time
    if [[ -n "${MEMBER_FAILED}" ]] || [[ "${ETCD_CLUSTER_IS_NOT_FULL}" == "true" ]]; then
      if curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevExist=false" \
        -XPUT -d value="${IPADDR}" 1>&2; then
        # Try to turn this proxy node as a etcd member

        if [[ -n "${MEMBER_FAILED}" ]]; then
          # Notify other node the failed member which will be replaced
          curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}" \
            -XPUT -d value="${MEMBER_FAILED}"

          # Set the remote failed etcd member to exit the etcd cluster
          /go/kube-down --exit-remote-etcd="${MEMBER_FAILED}"
          # Stop local k8s service
          /go/kube-down --stop-k8s-only
        else
          curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}" \
            -XPUT -d value="NULL"
        fi

        rejoin_etcd
        /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}"
        MEMBER_DISCONNECTED=""

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
          MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER_REMOVED}/d)"
        fi
      fi
    fi

    sleep "${HEALTH_CHECK_INTERVAL}"
  done


  echo "Running etcd-maintainer.sh ..."
}

main "$@"
