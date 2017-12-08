FROM golang:1.7.5
MAINTAINER hsfeng@gmail.com

ENV WORKDIR /workdir
WORKDIR /workdir

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get -y update && \
    apt-get -y install \
    net-tools \
    jq \
    iptables \
    bc \
    module-init-tools \
    uuid-runtime \
    ntpdate \
    openssh-server \
    vim \
    python \
    parted \
    gdisk \
    cgpt \
    iproute \
    kexec-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY . /workdir/

ENV PATH /opt/bin:$PATH

RUN mkdir -p /go/src \
    && ln -s /workdir/assets/k8sup/dnssd /go/src/dnssd \
    && cd /go/src/dnssd \
    && go get -u github.com/kardianos/govendor \
    && govendor sync \
    && go build -o /workdir/bin/dnssd-registering /go/src/dnssd/dnssd-registering/dnssd-registering.go \
    && go build -o /workdir/bin/dnssd-browsing /go/src/dnssd/dnssd-browsing/dnssd-browsing.go

ADD https://storage.googleapis.com/kubernetes-release/easy-rsa/easy-rsa.tar.gz /workdir/assets/k8sup/easy-rsa.tar.gz

ENTRYPOINT ["/workdir/entrypoint.sh"]

ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile

RUN rm -f /etc/ssh/sshd_config \
    && cp /workdir/assets/sshd/sshd_config /etc/ssh/

# Regenerating host keys of sshd
RUN mkdir /var/run/sshd \
    && mkdir -m 700 /root/.ssh \
    && rm -rf /etc/ssh/ssh_host* \
    && ssh-keygen -q -f /etc/ssh/ssh_host_dsa_key -N '' -t dsa \
    && ssh-keygen -q -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa \
    && ssh-keygen -q -f /etc/ssh/ssh_host_ecdsa_key -N '' -t ecdsa \
    && ssh-keygen -q -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519

EXPOSE 2222

ADD https://github.com/kubernetes-incubator/bootkube/releases/download/v0.9.0/bootkube.tar.gz /workdir/bootkube.tar.gz
RUN cd /workdir; \
  mkdir -p bootkube-dir; \
  tar xf bootkube.tar.gz -C bootkube-dir/; \
  mv bootkube-dir/bin/linux/bootkube .; \
  rm -rf bootkube-dir bootkube.tar.gz

RUN mkdir -p /go/src \
    && ln -s /workdir/assets/k8sup/kubelet-cert-distributor /go/src/kubelet-cert-distributor \
    && cd /go/src/kubelet-cert-distributor \
    && govendor sync \
    && go build -o /workdir/bin/kubelet-cert-distributor \
       /go/src/kubelet-cert-distributor/kubelet-cert-distributor.go
