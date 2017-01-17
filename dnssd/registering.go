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

func main() {
	rand.Seed(time.Now().UnixNano())
	if len(os.Args) != 7 {
		fmt.Printf("Usage: registering {Hostname} {IP/Mask} {Port} {etcd_cluster_ID} {etcd_proxy} {etcd_started}\n")
		return
	}
	NodeName := os.Args[1]
	IPMask := os.Args[2]
	Port, _ := strconv.Atoi(os.Args[3])
	clusterID := os.Args[4]
	etcdProxy := os.Args[5]
	etcdStarted := os.Args[6]
	IPAddr, Network, err := net.ParseCIDR(IPMask)
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
	s, err := bonjour.RegisterProxy(Instance, "_etcd._tcp", "", Port, NodeName, IPAddr.String(), SRVtext, nil)
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
