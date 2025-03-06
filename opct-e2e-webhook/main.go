package main

import (
	"context"
	"crypto/tls"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"

	admissionv1 "k8s.io/api/admission/v1"
	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/utils/ptr"
)

//go:embed static/*
var vfs embed.FS

type WebhookData struct {
	CertCA  string `json:"certCA"`
	TlsKey  string `json:"tlsKey"`
	TlsCert string `json:"tlsCert"`
}

const opctNamespace string = "opct"
const defaultWebhookName string = "opct-e2e-webhook"

var (
	// webhookFailurePolicy is ignore so we don't want to block machine lifecycle on the webhook operational aspects.
	// This would be particularly problematic for chicken egg issues when bootstrapping a cluster.
	webhookFailurePolicy = admissionregistrationv1.Ignore
	webhookSideEffects   = admissionregistrationv1.SideEffectClassNone
)

// MachineMutatingWebhook returns mutating webhooks for machine to apply in configuration
func newMutatingWebhook() admissionregistrationv1.MutatingWebhook {
	serviceReference := admissionregistrationv1.ServiceReference{
		Namespace: opctNamespace,
		Name:      defaultWebhookName,
		Path:      ptr.To[string]("/mutate"),
		Port:      ptr.To[int32](443),
	}
	return admissionregistrationv1.MutatingWebhook{
		AdmissionReviewVersions: []string{"v1"},
		Name:                    "opct-e2e-webhook.opct.svc",
		FailurePolicy:           &webhookFailurePolicy,
		SideEffects:             &webhookSideEffects,
		ClientConfig: admissionregistrationv1.WebhookClientConfig{
			Service: &serviceReference,
		},
		Rules: []admissionregistrationv1.RuleWithOperations{
			{
				Rule: admissionregistrationv1.Rule{
					APIGroups:   []string{""},
					APIVersions: []string{"v1"},
					Resources:   []string{"pods"},
				},
				Operations: []admissionregistrationv1.OperationType{
					admissionregistrationv1.Create,
				},
			},
		},
	}
}

// NewMutatingWebhookConfiguration creates a mutating webhook configuration with configured Machine and MachineSet webhooks
func newMutatingWebhookConfiguration() *admissionregistrationv1.MutatingWebhookConfiguration {
	mutatingWebhookConfiguration := &admissionregistrationv1.MutatingWebhookConfiguration{
		ObjectMeta: metav1.ObjectMeta{
			Name: "opct-e2e-webhook",
			Annotations: map[string]string{
				"service.beta.openshift.io/inject-cabundle": "true",
			},
		},
		Webhooks: []admissionregistrationv1.MutatingWebhook{
			newMutatingWebhook(),
		},
	}

	// Setting group version is required for testEnv to create unstructured objects, as the new structure sets it on empty strings
	// Usual way to populate those values, is to create the resource in the cluster first, which we can't yet do.
	mutatingWebhookConfiguration.SetGroupVersionKind(admissionregistrationv1.SchemeGroupVersion.WithKind("MutatingWebhookConfiguration"))
	return mutatingWebhookConfiguration
}

func createWebhook(clientset *kubernetes.Clientset) error {
	// templateFile, err := vfs.ReadFile("static/MutationWebhookConfiguratoin.yaml")
	// if err != nil {
	// 	fmt.Printf("Failed to read template file: %v\n", err)
	// 	os.Exit(1)
	// }

	// pluginTpl, err := template.New("manifest").Parse(string(templateFile))
	// if err != nil {
	// 	return errors.Wrapf(err, "unable to parse manifest ")
	// }
	// var imageBuffer bytes.Buffer
	// err = pluginTpl.Execute(&imageBuffer, webhookData)
	// if err != nil {
	// 	return errors.Wrapf(err, "unable to update manifest")
	// }

	// renderedTemplate := imageBuffer.Bytes()
	// fmt.Printf("Rendered Template: %s\n", renderedTemplate)

	fmt.Println("Creating the webhookconfig...")
	webhookConfig := newMutatingWebhookConfiguration()

	// var webhookConfig admissionregistrationv1.MutatingWebhookConfiguration
	// webhookConfig := &admissionregistrationv1.MutatingWebhookConfiguration{
	// 	ObjectMeta: metav1.ObjectMeta{
	// 		Name: "opct-e2e-webhook",
	// 	},
	// }

	// webhookConfig.Webhook = append(webhookConfig.Webhook, wk...)

	// if err := json.Unmarshal([]byte(renderedTemplate), webhookConfig); err != nil {
	// 	fmt.Printf("Failed to unmarshal rendered template: %v\n", err)
	// 	os.Exit(1)
	// }

	_, err := clientset.AdmissionregistrationV1().MutatingWebhookConfigurations().Create(context.Background(), webhookConfig, metav1.CreateOptions{})
	if err != nil {
		fmt.Printf("Failed to create MutatingWebhookConfiguration: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Successfully applied MutatingWebhookConfiguration")

	return nil
}

func main() {
	tlsCert := flag.String("tls-cert", "/var/run/app/certs/tls.crt", "Path to the TLS certificate file.")
	tlsKey := flag.String("tls-key", "/var/run/app/certs/tls.key", "Path to the TLS key file.")
	tlsCA := flag.String("tls-cert-ca", "/var/run/app/cacerts/service-ca.crt", "Path to the TLS Cert CA.")
	// wkName := flag.String("webhook-name", "opct-e2e-webhook", "Mutation Webhook Name.")
	flag.Parse()

	if _, err := os.Stat(*tlsCert); os.IsNotExist(err) {
		fmt.Printf("TLS certificate file does not exist: %s\n", *tlsCert)
		os.Exit(1)
	}

	if _, err := os.Stat(*tlsKey); os.IsNotExist(err) {
		fmt.Printf("TLS key file does not exist: %s\n", *tlsKey)
		os.Exit(1)
	}

	if _, err := os.Stat(*tlsCA); os.IsNotExist(err) {
		fmt.Printf("TLS CA certificate file does not exist: %s\n", *tlsCA)
		os.Exit(1)
	}

	// caCert, err := os.ReadFile(*tlsCA)
	// if err != nil {
	// 	fmt.Printf("Failed to read CA certificate: %v\n", err)
	// 	os.Exit(1)
	// }

	// webhookData := &WebhookData{
	// 	CertCA: base64.StdEncoding.EncodeToString(caCert),
	// }

	fmt.Println("Creating the rest client")
	config, err := rest.InClusterConfig()
	if err != nil {
		fmt.Printf("Failed to get in-cluster config: %v\n", err)
		os.Exit(1)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		fmt.Printf("Failed to create clientset: %v\n", err)
		os.Exit(1)
	}

	if err := createWebhook(clientset); err != nil {
		fmt.Printf("Failed to create webhook: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Starting watch pods...")
	go watchPods(clientset)

	http.HandleFunc("/mutate", handleMutate)
	server := &http.Server{
		Addr:      ":8443",
		TLSConfig: configTLS(tlsKey, tlsCert),
	}
	fmt.Println("Starting server on :8443")
	server.ListenAndServeTLS(*tlsCert, *tlsKey)
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	fmt.Println("Received a request for mutation")
	body, err := io.ReadAll(r.Body)
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

	fmt.Printf("Checking pod.Name: %s/%s\n", pod.ObjectMeta.Namespace, pod.ObjectMeta.Name)
	fmt.Printf("Checking pod.Spec.NodeName: %s\n", pod.Spec.NodeName)
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

func configTLS(tlsKey *string, tlsCert *string) *tls.Config {
	cert, err := tls.LoadX509KeyPair(*tlsCert, *tlsKey)
	if err != nil {
		fmt.Printf("Failed to load key pair: %v\n", err)
		os.Exit(1)
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
	}
}
