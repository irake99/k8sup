#!/bin/bash

KUBECTL=${KUBECTL_BIN:-/hyperkube kubectl}
KUBECTL_OPTS=${KUBECTL_OPTS:-}

function main(){

  sed -i "s|^  labels:|  labels:\n    kubernetes.io/cluster-service: 'true'|g" /etc/kubernetes/addons/multinode/heapster/*-controller.yaml

  /copy-addons.sh "$@" &

  token_found=""
  while [ -z "${token_found}" ]; do
    sleep .5
    token_found=$(${KUBECTL} ${KUBECTL_OPTS} get --namespace="kube-system" serviceaccount default -o go-template="{{with index .secrets 0}}{{.name}}{{end}}" || true)
  done

  echo "== default service account in the kube-system namespace has token ${token_found} =="

  while true; do
	  sleep 3600;
  done
}

main "$@"
