# environment variables and configs

# Make alias work in non-interactive environment
shopt -s expand_aliases

alias curl-k8s='curl \
  --cacert /var/lib/kubelet/kubeconfig/ca.crt \
  --cert /var/lib/kubelet/kubeconfig/kubecfg.crt \
  --key /var/lib/kubelet/kubeconfig/kubecfg.key'
