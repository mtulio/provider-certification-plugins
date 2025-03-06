package main

import (
	"context"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/retry"
)

func watchPods(clientset *kubernetes.Clientset) {
	watchlist := cache.NewListWatchFromClient(
		clientset.CoreV1().RESTClient(),
		"pods",
		corev1.NamespaceAll,
		fields.Everything(),
	)

	_, controller := cache.NewInformer(
		watchlist,
		&corev1.Pod{},
		0,
		cache.ResourceEventHandlerFuncs{
			UpdateFunc: func(oldObj, newObj interface{}) {
				newPod := newObj.(*corev1.Pod)
				// ensure only e2e and opct (for tests) will be changed
				if strings.HasPrefix(newPod.Namespace, "e2e-") || strings.HasPrefix(newPod.Namespace, "opct") {
					for _, condition := range newPod.Status.Conditions {
						// act only when the pod failed to schedule due the opct environment: one random worker node has taints preventing scheduling the node.
						if condition.Type == corev1.PodScheduled && condition.Status == corev1.ConditionFalse && condition.Reason == corev1.PodReasonUnschedulable {
							handleFailedScheduling(clientset, newPod)
						}
					}
				}
			},
		},
	)

	// controller := cache.NewSharedInformer(watchlist, &corev1.Pod{}, 0)
	stop := make(chan struct{})
	defer close(stop)
	go controller.Run(stop)

	select {}
}

func handleFailedScheduling(clientset *kubernetes.Clientset, pod *corev1.Pod) {
	fmt.Printf("Handling failed scheduling for pod: %s/%s\n", pod.Namespace, pod.Name)

	retryErr := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		pod, err := clientset.CoreV1().Pods(pod.Namespace).Get(context.Background(), pod.Name, metav1.GetOptions{})
		if err != nil {
			return err
		}

		toleration := corev1.Toleration{
			Key:      "node-role.kubernetes.io/tests",
			Operator: corev1.TolerationOpExists,
			Effect:   corev1.TaintEffectNoSchedule,
		}
		pod.Spec.Tolerations = append(pod.Spec.Tolerations, toleration)

		_, updateErr := clientset.CoreV1().Pods(pod.Namespace).Update(context.Background(), pod, metav1.UpdateOptions{})
		return updateErr
	})

	if retryErr != nil {
		fmt.Printf("Failed to update pod: %v\n", retryErr)
	} else {
		fmt.Printf("Successfully added toleration to pod: %s/%s\n", pod.Namespace, pod.Name)
	}
}
