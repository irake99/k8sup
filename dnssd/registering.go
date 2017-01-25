package main

import (
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"time"

	"github.com/oleksandr/bonjour"
)

func getInterfaceByIPNet(Net *net.IPNet) (*net.Interface, error) {
	ift, err := net.Interfaces()
	if err != nil {
		panic(err)
	}
	for _, iface := range ift {
		addrs, err := iface.Addrs()
		if err != nil {
			panic(err)
		}
		for _, addr := range addrs {
			IPaddr, _, _ := net.ParseCIDR(addr.String())
			if Net.Contains(IPaddr) {
				return &iface, nil
			}
		}
	}
	err = fmt.Errorf("No such interface by the given network: %s", Net.String())
	return nil, err
}

func main() {
	rand.Seed(time.Now().UnixNano())
	if len(os.Args) != 8 {
		fmt.Printf("Usage: registering {Hostname} {IP/Mask} {Port} {etcd_cluster_ID} {etcd_proxy} {etcd_started} {all_interfaces}\n")
		return
	}
	NodeName := os.Args[1]
	IPMask := os.Args[2]
	Port, _ := strconv.Atoi(os.Args[3])
	clusterID := os.Args[4]
	etcdProxy := os.Args[5]
	etcdStarted := os.Args[6]
	AllIfaces := os.Args[7]
	IPAddr, Network, err := net.ParseCIDR(IPMask)

	// Registering for all interfaces or specific interface
	var iface *net.Interface
	if AllIfaces == "true" {
		iface = nil
	} else {
		iface, err = getInterfaceByIPNet(Network)
		if err != nil {
			panic(err)
		}
	}

	var SRVtext []string
	if clusterID != "" {
		SRVtext = append(SRVtext, "clusterID="+clusterID)
	}
	SRVtext = append(SRVtext, "IPAddr="+IPAddr.String())
	SRVtext = append(SRVtext, "etcdPort="+strconv.Itoa(Port))
	SRVtext = append(SRVtext, "etcdProxy="+etcdProxy)
	SRVtext = append(SRVtext, "etcdStarted="+etcdStarted)
	SRVtext = append(SRVtext, "NetworkID="+Network.String())
	SRVtext = append(SRVtext, "NodeName="+NodeName)
	SRVtext = append(SRVtext, "UnixNanoTime="+strconv.FormatInt(time.Now().UnixNano(), 10))
	fmt.Printf("Registering: %s %s:%d %s\n", NodeName, IPAddr, Port, clusterID)
	Instance := fmt.Sprintf("%016X", rand.Int63())
	Instance = NodeName + "-" + Instance
	// Run registration (blocking call)
	s, err := bonjour.RegisterProxy(Instance, "_etcd._tcp", "", Port, NodeName, IPAddr.String(), SRVtext, iface)
	if err != nil {
		log.Fatalln(err.Error())
	}

	// etcd health check (If it down, stop mDNS)
	if etcdStarted == "true" {
		go func() {
			client := &http.Client{
				Timeout: time.Duration(5e9),
			}
			etcdURL := "http://127.0.0.1:" + strconv.Itoa(Port) + "/health"
			for {
				// Check etcd every 5 seconds
				time.Sleep(5e9)
				_, err := client.Get(etcdURL)
				if err != nil {
					fmt.Println("mDNS stopped!")
					s.Shutdown()
					time.Sleep(1e9)
					os.Exit(0)
				}
			}
		}()
	}

	fmt.Println("Press Ctrl+C to stop...")
	// Ctrl+C handling
	handler := make(chan os.Signal, 1)
	signal.Notify(handler, os.Interrupt)
	go func() {
		for sig := range handler {
			fmt.Println(sig)
			if sig == os.Interrupt {
				s.Shutdown()
				time.Sleep(1e9)
				os.Exit(0)
			}
		}
	}()

	select {}
}
