package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

func main() {
	http.HandleFunc("/mutate", handleMutate)
	server := &http.Server{
		Addr:      ":8443",
		TLSConfig: configTLS(),
	}
	fmt.Println("Starting server on :8443")
	server.ListenAndServeTLS("/path/to/tls.crt", "/path/to/tls.key")
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := ioutil.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "could not read request body", http.StatusBadRequest)
		return
	}

	var admissionReview admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		http.Error(w, "could not unmarshal request", http.StatusBadRequest)
		return
	}

	pod := corev1.Pod{}
	if err := json.Unmarshal(admissionReview.Request.Object.Raw, &pod); err != nil {
		http.Error(w, "could not unmarshal pod object", http.StatusBadRequest)
		return
	}

	// Check if the pod is scheduled on a node with the label "node-role.kubernetes.io/tests"
	if pod.Spec.NodeName != "" {
		config, err := rest.InClusterConfig()
		if err != nil {
			http.Error(w, "could not get in-cluster config", http.StatusInternalServerError)
			return
		}

		clientset, err := kubernetes.NewForConfig(config)
		if err != nil {
			http.Error(w, "could not create clientset", http.StatusInternalServerError)
			return
		}

		// TODO move to a function to async get nodes and return the desired node, something like:
		// isDedicatedNode(nodeName string) (bool, error)
		node, err := clientset.CoreV1().Nodes().Get(context.Background(), pod.Spec.NodeName, metav1.GetOptions{})
		if err != nil {
			http.Error(w, "could not get node", http.StatusInternalServerError)
			return
		}

		if _, ok := node.Labels["node-role.kubernetes.io/tests"]; ok {
			// Mutate the pod to add tolerations
			toleration := corev1.Toleration{
				Key:      "node-role.kubernetes.io/tests",
				Operator: corev1.TolerationOpExists,
				Effect:   corev1.TaintEffectNoSchedule,
			}
			pod.Spec.Tolerations = append(pod.Spec.Tolerations, toleration)

			patchBytes, err := json.Marshal(map[string]interface{}{
				"spec": map[string]interface{}{
					"tolerations": pod.Spec.Tolerations,
				},
			})
			if err != nil {
				http.Error(w, "could not marshal patch", http.StatusInternalServerError)
				return
			}

			admissionResponse := admissionv1.AdmissionResponse{
				Allowed: true,
				Patch:   patchBytes,
				PatchType: func() *admissionv1.PatchType {
					pt := admissionv1.PatchTypeJSONPatch
					return &pt
				}(),
			}

			admissionReview.Response = &admissionResponse
			admissionReview.Response.UID = admissionReview.Request.UID

			responseBytes, err := json.Marshal(admissionReview)
			if err != nil {
				http.Error(w, "could not marshal response", http.StatusInternalServerError)
				return
			}

			w.Header().Set("Content-Type", "application/json")
			w.Write(responseBytes)
			return
		}
	}

	admissionReview.Response = &admissionv1.AdmissionResponse{
		Allowed: true,
		UID:     admissionReview.Request.UID,
	}

	responseBytes, err := json.Marshal(admissionReview)
	if err != nil {
		http.Error(w, "could not marshal response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(responseBytes)
}

func configTLS() *tls.Config {
	cert, err := tls.LoadX509KeyPair("/path/to/tls.crt", "/path/to/tls.key")
	if err != nil {
		fmt.Printf("Failed to load key pair: %v\n", err)
		os.Exit(1)
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
	}
}
