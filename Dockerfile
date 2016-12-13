FROM golang:1.6.3
MAINTAINER hsfeng@gmail.com

RUN apt-get -y update

RUN apt-get -y install net-tools jq iptables bc module-init-tools uuid-runtime psmisc

RUN go get "github.com/oleksandr/bonjour"

RUN mkdir -p /go/downloads && curl -sf -o /go/downloads/heapster.tar.gz -L https://github.com/kubernetes/heapster/archive/v1.2.0.tar.gz && tar xfz /go/downloads/heapster.tar.gz && rm -rf /go/downloads/heapster.tar.gz

COPY cni-conf /go/cni-conf
COPY kube-conf /go/kube-conf
COPY dnssd /go/dnssd
COPY flannel-conf /go/flannel-conf

WORKDIR /go

ADD kube-up /go/kube-up
ADD kube-down /go/kube-down
ADD entrypoint.sh /go/entrypoint.sh
ADD cp-certs.sh /go/cp-certs.sh
ADD update-addons.sh /go/update-addons.sh

RUN chmod +x /go/entrypoint.sh
RUN chmod +x /go/kube-up

ENTRYPOINT ["/go/entrypoint.sh"]
CMD []
