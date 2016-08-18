package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"time"

	"github.com/oleksandr/bonjour"
)

func main() {
	if len(os.Args) != 5 {
		fmt.Printf("Usage: registering {Hostname} {IP} {Port} {etcd_cluster_ID}\n")
		return
	}
	Hostname := os.Args[1]
	IPAddr := os.Args[2]
	Port, _ := strconv.Atoi(os.Args[3])
	clusterID := os.Args[4]
	fmt.Printf("Registering: %s %s:%d %s\n", Hostname, IPAddr, Port, clusterID)
	// Run registration (blocking call)
	s, err := bonjour.RegisterProxy(clusterID, "_etcd._tcp", "", Port, Hostname, IPAddr, []string{clusterID}, nil)
	if err != nil {
		log.Fatalln(err.Error())
	}

	// etcd health check (If it down, stop mDNS)
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
