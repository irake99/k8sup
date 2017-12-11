package main

import (
	"encoding/base64"
	"flag"
	"io/ioutil"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
)

var (
	kubeconfigPath   = flag.String("kubeconfig", "/etc/kubernetes/kubeconfig", "Path to kubeconfig file.")
	kubeletCAPath    = flag.String("ca", "/etc/kubernetes/ca.crt", "Path to kubelet ca.crt file.")
	kubeconfigBase64 *string
	kubeletCABase64  *string
)

func init() {
	var err error
	kubeconfigBase64, err = readFileAndEncodeBase64(kubeconfigPath)
	if err != nil {
		log.Fatalln(err.Error())
	}

	kubeletCABase64, err = readFileAndEncodeBase64(kubeletCAPath)
	if err != nil {
		log.Fatalln(err.Error())
	}
}

func readFileAndEncodeBase64(path *string) (*string, error) {
	tmp, err := ioutil.ReadFile(*path)
	if err != nil {
		return nil, err
	}
	encoded := base64.StdEncoding.EncodeToString(tmp)
	return &encoded, nil
}

func main() {
	router := gin.Default()
	router.GET("/", func(c *gin.Context) {
		c.JSON(http.StatusNotFound, gin.H{"message": "Resource not found"})
	})

	router.GET("/kubeconfig", getKubeconfigHandler)
	router.GET("/kubeletca", getKubeletCAHandler)

	router.Run(":23555")
}

func getKubeconfigHandler(c *gin.Context) {
	c.JSON(http.StatusOK, kubeconfigBase64)
}

func getKubeletCAHandler(c *gin.Context) {
	c.JSON(http.StatusOK, kubeletCABase64)
}
