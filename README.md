# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster

`$ git clone https://github.com/hsfeng/k8sup`

`$ cd hyperkube-utils-on-coreos`

`$ docker build -t k8sup .`

`$ docker run -it --privileged --net=host --pid=host -v /:/rootfs -v /bin/docker:/bin/docker -v /var/run/docker.sock:/var/run/docker.sock -v /usr/lib/libdevmapper.so.1.02:/usr/lib/libdevmapper.so.1.02 -v /dev:/dev -v /sys:/sys -v /etc/cni:/etc/cni -v /opt/cni:/opt/cni -v /var/lib/cni:/var/lib/cni -v /var/lib/etcd:/var/lib/etcd k8sup 192.168.32.56`
