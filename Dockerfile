FROM golang:1.6.3
MAINTAINER hsfeng@gmail.com

RUN apt-get -y update

RUN apt-get -y install net-tools jq iptables bc module-init-tools uuid-runtime

RUN git clone https://github.com/containernetworking/cni.git && go get "github.com/oleksandr/bonjour"

COPY cni-conf /go/cni-conf
COPY kube-conf /go/kube-conf
COPY dnssd /go/dnssd
COPY flannel-conf /go/flannel-conf

WORKDIR /go/cni
RUN ./build

ADD kube-up /go/kube-up
ADD entrypoint.sh /go/entrypoint.sh
ADD cp-certs.sh /go/cp-certs.sh

RUN chmod +x /go/entrypoint.sh
RUN chmod +x /go/kube-up

ENTRYPOINT ["/go/entrypoint.sh"]
CMD []
