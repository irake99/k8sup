package main

import (
	"fmt"
	"log"
	"os"
	"time"

	"github.com/oleksandr/bonjour"
)

func main() {
	resolver, err := bonjour.NewResolver(nil)
	if err != nil {
		log.Println("Failed to initialize resolver:", err.Error())
		os.Exit(1)
	}

	results := make(chan *bonjour.ServiceEntry)

	// Send the "stop browsing" signal after the desired timeout
	timeout := time.Duration(5e9)
	exitCh := make(chan bool)
	go func() {
		time.Sleep(timeout)
		go func() { resolver.Exit <- true }()
		go func() { exitCh <- true }()
	}()

	err = resolver.Browse("_etcd._tcp", "local.", results)
	if err != nil {
		log.Println("Failed to browse:", err.Error())
	}

	for {
		select {
		case e := <-results:
			fmt.Printf("%s %s:%d %s\n", e.HostName, e.AddrIPv4, e.Port, e.Text[0])
			time.Sleep(1e8)
		case <-exitCh:
			os.Exit(0)
		}
	}
}
