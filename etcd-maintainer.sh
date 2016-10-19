#!/bin/bash

function remove_member_from_etcd(){
  local IPADDR="$1"
  local ETCD_CLIENT_PORT="$2"

  # Set the remote failed etcd member to exit the etcd cluster
  local MEMBER_LIST="$(curl -s http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members)"
  if [[ "${MEMBER_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
    local MEMBER_ID="$(echo "${MEMBER_LIST}" | jq -r ".members[] | select(contains({clientURLs: [\"/${IPADDR}:\"]})) | .id")"
    test "${MEMBER_ID}" && curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members/${MEMBER_ID}" -XDELETE \
      || { echo "Can not write etcd, exiting..." 1>&2; exit 1; }
  else
    echo "This node is not an etcd member" 1>&2
    exit 1
  fi
}

function rejoin_etcd(){
  /go/entrypoint.sh --rejoin-etcd
}

function main(){
  source "/root/.bashrc" || exit 1
  local IPADDR="${EX_IPADDR}"
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}"

  local MEMBER_CLIENT_ADDR_LIST
  local MEMBER_SIZE
  local MEMBER
  local MEMBER_DISCONNECTED
  local MEMBER_FAILED
  local MEMBER_REMOVED
  local HEALTH_CHECK_INTERVAL="30"
  local UNHEALTH_COUNT="0"
  local UNHEALTH_COUNT_THRESHOLD="3"
  local IP_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
  local LOCKER_ETCD_KEY="k8sup/cluster/etcd-rejoining"
  local MEMBER_REMOVED_KEY="k8sup/cluster/member-removed"
  while true; do

    # If I am already etcd member, do nothing...
    if [[ "$(docker inspect k8sup-etcd | jq -r -c .[].Args | sed -n "s/.*\"--proxy\",\"\(.*\)\"\]/\1/p")" == "off" ]]; then
      sleep 60
      continue
    fi

    # If I am a etcd proxy...
    # Monitoring all etcd members and try to get one of the failed member
    MEMBER_CLIENT_ADDR_LIST="$(curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members" | jq -r ".members[].clientURLs[0]")"
    MEMBER_SIZE="$(echo "${MEMBER_CLIENT_ADDR_LIST}" | wc -l)"
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
    if [[ -n "${MEMBER_FAILED}" ]]; then
      if curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}?prevExist=false" \
        -XPUT -d value="${IPADDR}" 1>&2; then
        # Try to turn this proxy node as a etcd member

        curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${MEMBER_REMOVED_KEY}" \
          -XPUT -d value="${MEMBER_FAILED}"

        remove_member_from_etcd "${MEMBER_FAILED}" "${ETCD_CLIENT_PORT}"
        rejoin_etcd
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
        MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER_REMOVED}/d)"
      fi
    fi

    sleep "${HEALTH_CHECK_INTERVAL}"
  done


  echo "Running etcd-maintainer.sh ..."
}

main "$@"
