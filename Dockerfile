FROM golang:1.7.5
MAINTAINER hsfeng@gmail.com

WORKDIR /workdir

RUN apt-get -y update

RUN apt-get -y install net-tools jq iptables bc module-init-tools uuid-runtime ntpdate && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY assets /workdir/assets
COPY bin /workdir/bin
COPY entrypoint.sh /workdir/

RUN mkdir -p /go/src \
    && ln -s /workdir/assets/k8sup/dnssd /go/src/dnssd \
    && cd /go/src/dnssd \
    && go get -u github.com/kardianos/govendor \
    && govendor sync \
    && go build -o /workdir/assets/k8sup/src/dnssd/registering /go/src/dnssd/registering.go \
    && go build -o /workdir/assets/k8sup/src/dnssd/browsing /go/src/dnssd/browsing.go

ADD https://storage.googleapis.com/kubernetes-release/easy-rsa/easy-rsa.tar.gz /workdir/assets/k8sup/easy-rsa.tar.gz

ENTRYPOINT ["/workdir/entrypoint.sh"]
CMD []
