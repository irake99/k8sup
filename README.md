# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster.

Auto discovery and add to the first discovered etcd cluster.

<pre>
$ git clone https://github.com/irake99/k8sup.git

$ cd k8sup

$ docker build -t k8sup .

$ sudo docker run -it \
    --privileged \
    --net=host \
    --pid=host \
    -v $(which docker):/bin/docker \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/libdevmapper.so.1.02:/usr/lib/libdevmapper.so.1.02 \
    -v /etc/cni:/etc/cni \
    -v /opt/cni:/opt/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /etc/kubernetes:/etc/kubernetes \
    k8sup \
    {your-host-ip}
</pre>

If you want to delete etcd data:
<pre>
$ sudo rm -rf /var/lib/etcd/*
</pre>
