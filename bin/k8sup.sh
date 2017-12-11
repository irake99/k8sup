#!/bin/bash

if [[ ! -f "/.dockerenv" ]] || [[ ! -f "/workdir/assets/k8sup/k8sup.sh" ]]; then
  echo "Wrong environment, exiting..." 1>&2
  exit 1
fi

/workdir/assets/k8sup/k8sup.sh "$@"
