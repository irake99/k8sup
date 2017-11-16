#!/bin/bash

# k8sup
if [[ "${NO_K8SUP}" != "true" ]]; then
  /workdir/bin/k8sup.sh "$@" &

  # TODO
  # wait for k8s started

  # TODO
  # Try to get ssh keys from k8s secrets
fi

sleep infinity
