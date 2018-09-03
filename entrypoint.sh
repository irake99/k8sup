#!/bin/bash

# Environment variables
ENV_KUBECONFIG_PATH="/etc/kubernetes/kubeconfig"
ENV_PKI="/etc/kubernetes/pki"

# Make alias work in non-interactive environment
shopt -s expand_aliases

function get_tls_data(){
  local DATA DATA_PATH DATA_KEY="$1"
  DATA="$(sed -n "s|\s*${DATA_KEY}-data: \(.*\)|\1|p" "${ENV_KUBECONFIG_PATH}")"
  if [[ -n "${DATA}" ]]; then
    echo "${DATA}" | base64 -d
    return 0
  fi
  DATA_PATH="$(sed -n "s|\s*${DATA_KEY}: \(.*\)|\1|p" "${ENV_KUBECONFIG_PATH}")"
  if [[ -s "${DATA_PATH}" ]]; then
    cat "${DATA_PATH}"
    return 0
  else
    echo "could not get TLS data of ${DATA_KEY}" 1>&2
    return 1
  fi
}

function make_k8s_tls_certs(){
  local ENV_PKI CA CERT KEY
  until [[ -s "${ENV_KUBECONFIG_PATH}" ]]; do
    echo "[sync_ssh_keys] wait for ${ENV_KUBECONFIG_PATH} existing..." 1>&2
    sleep 5
  done
  CA="$(get_tls_data "certificate-authority")" || exit "$?"
  CERT="$(get_tls_data "client-certificate")" || exit "$?"
  KEY="$(get_tls_data "client-key")" || exit "$?"

  ENV_PKI="/etc/kubernetes/pki"
  mkdir -p "${ENV_PKI}"
  echo "${CA}"   > "${ENV_PKI}/ca.crt"
  echo "${CERT}" > "${ENV_PKI}/kubelet.crt"
  echo "${KEY}"  > "${ENV_PKI}/kubelet.key"
}

function hold_until_kube_apiserver_started(){
  local URL="https://10.0.0.1:443/api/v1/namespaces/kube-public/configmaps/cluster-info"
  until curl -ksf "${URL}" &>/dev/null; do
    sleep 1
  done
}

function get_all_authorized_keys_from_k8s_secrets(){
  local INTERVAL="10"
  local KEYS DECODED_KEYS URL RESPONSE KEY_FILE=~/".ssh/authorized_keys"
  if [[ ! -f "${KEY_FILE}" ]]; then
    mkdir -p ~/".ssh"
    touch "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
  fi
  URL="https://10.0.0.1:443/api/v1/namespaces/kube-system/secrets/k8sup-authorized-keys"
  while true; do
    DECODED_KEYS=""
    RESPONSE="$(curl -sf "${URL}" \
              --cacert "${ENV_PKI}/ca.crt" \
              --cert "${ENV_PKI}/kubelet.crt" \
              --key "${ENV_PKI}/kubelet.key" \
              2>/dev/null)"
    if [[ "$?" != "0" ]]; then
      # Failed to get the response from the kube-apiserver
      # Try again
      continue
    fi
    KEYS="$(echo "${RESPONSE}" | jq -r '.data[]?' 2>/dev/null)"
    # If no such keys on k8s, then erase authorized_keys file for keeping synchronized status
    if [[ -z "${KEYS}" ]]; then
      if [[ -s "${KEY_FILE}" ]]; then
        > "${KEY_FILE}"
        echo "authorized_keys updated!"
      fi
      sleep "${INTERVAL}"
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
    sleep "${INTERVAL}"
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
    make_k8s_tls_certs
    get_all_authorized_keys_from_k8s_secrets &
  fi

  # hold
  /usr/bin/tail -f /dev/null
}

main "$@"
