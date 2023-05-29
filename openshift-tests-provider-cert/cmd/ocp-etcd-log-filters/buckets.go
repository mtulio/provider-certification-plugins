package main

func buckets1s() []string {
	return []string{
		"low-200",
		"200-300",
		"300-400",
		"400-500",
		"500-600",
		"600-700",
		"700-800",
		"800-900",
		"900-1s",
		"1s-inf",
		"all",
	}
}

func buckets500ms() []string {
	return []string{
		"low-200",
		"200-300",
		"300-400",
		"400-500",
		"500-inf",
		"all",
	}
}

type Buckets map[string][]float64

func NewBuckets(values []string) Buckets {
	buckets := make(Buckets, len(values))
	for _, v := range values {
		buckets[v] = []float64{}
	}
	return buckets
}
