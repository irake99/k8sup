#!/bin/bash

# Environment variables
ENV_CA_FILEPATH="/etc/kubernetes/ca.crt"
ENV_TOKEN_PATH="/etc/kubernetes/tokens/admin"
ENV_INTERVAL="10"

# Make alias work in non-interactive environment
shopt -s expand_aliases

function get_admin_token(){
  until [[ -s "${ENV_TOKEN_PATH}" ]]; do
    sleep "${ENV_INTERVAL}"
  done
  cat "${ENV_TOKEN_PATH}"
}

function hold_until_kube_apiserver_started(){
  local URL="https://10.0.0.1:443/api/v1/namespaces/kube-public/configmaps/cluster-info"
  until curl -ksf "${URL}" &>/dev/null \
    && [[ -s "${ENV_TOKEN_PATH}" ]]; do
    sleep 1
  done
}

function get_all_authorized_keys_from_k8s_secrets(){
  local KEYS DECODED_KEYS URL RESPONSE TOKEN KEY_FILE=~/".ssh/authorized_keys"
  TOKEN="$(get_admin_token)"
  if [[ ! -f "${KEY_FILE}" ]]; then
    mkdir -p ~/".ssh"
    touch "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
  fi
  URL="https://10.0.0.1:443/api/v1/namespaces/kube-system/secrets/k8sup-authorized-keys"
  while true; do
    DECODED_KEYS=""
    RESPONSE="$(curl -sf "${URL}" \
                  --cacert "${ENV_CA_FILEPATH}" \
                  -H "Authorization: Bearer ${TOKEN}" \
                  2>/dev/null)"
    if [[ "$?" != "0" ]]; then
      # Failed to get the response from the kube-apiserver
      # Try again
      sleep "${ENV_INTERVAL}"
      continue
    fi
    KEYS="$(echo "${RESPONSE}" | jq -r '.data[]?' 2>/dev/null)"
    # If no such keys on k8s, then erase authorized_keys file for keeping synchronized status
    if [[ -z "${KEYS}" ]]; then
      if [[ -s "${KEY_FILE}" ]]; then
        > "${KEY_FILE}"
        echo "authorized_keys updated!"
      fi
      sleep "${ENV_INTERVAL}"
      continue
    fi
    # Decode line by line, because this base64 command doesn't support multiple line decoding
    for KEY in ${KEYS}; do
      DECODED_KEYS="$(echo "${KEY}" | base64 -d)"$'\n'"${DECODED_KEYS}"
    done
    # Remove the extra last character '\n'
    DECODED_KEYS="$(echo "${DECODED_KEYS}" | head -c -1)"
    # Update file if keys have been changed
    if ! cmp -s "${KEY_FILE}" <(echo "${DECODED_KEYS}"); then
      echo "${DECODED_KEYS}" > "${KEY_FILE}"
      echo "authorized_keys updated!"
    fi
    sleep "${ENV_INTERVAL}"
  done
}

function init(){
  mkdir -p "/opt/bin"
  cp -f "${WORKDIR}/bin"/* "/opt/bin/"
}

function main(){
  init

  # Start SSH daemon
  /usr/sbin/sshd

  # k8sup
  if [[ "${NO_K8SUP}" != "true" ]]; then
    /opt/bin/k8sup.sh "$@" &

    # wait for k8s started
    hold_until_kube_apiserver_started

    # Try to get client ssh keys from k8s secrets
    get_all_authorized_keys_from_k8s_secrets &
  fi

  # hold
  /usr/bin/tail -f /dev/null
}

main "$@"
