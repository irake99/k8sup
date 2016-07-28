# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster

`$ git clone https://github.com/hsfeng/k8sup`

`$ cd k8sup`

`$ docker build -t k8sup .`

`$ sudo docker run -it --privileged --net=host --pid=host -v $(which docker):/bin/docker -v /var/run/docker.sock:/var/run/docker.sock -v /usr/lib/libdevmapper.so.1.02:/usr/lib/libdevmapper.so.1.02 -v /etc/cni:/etc/cni -v /opt/cni:/opt/cni k8sup <host-ip>`
