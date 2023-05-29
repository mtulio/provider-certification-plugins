package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/montanaflynn/stats"
)

// LogPayloadETCD parses the etcd log file to extract insights
// {"level":"warn","ts":"2023-03-01T15:14:22.192Z",
// "caller":"etcdserver/util.go:166",
// "msg":"apply request took too long",
// "took":"231.023586ms","expected-duration":"200ms",
// "prefix":"read-only range ",
// "request":"key:\"/kubernetes.io/configmaps/kube-system/kube-controller-manager\" ",
// "response":"range_response_count:1 size:608"}
type LogPayloadETCD struct {
	Took      string `json:"took"`
	Timestamp string `json:"ts"`
}

type BucketGroup struct {
	Bukets1s    Buckets
	Bukets500ms Buckets
}

type FilterApplyTookTooLong struct {
	Name    string
	GroupBy string
	Group   map[string]*BucketGroup

	// filter config
	lineFilter     string
	reLineSplitter *regexp.Regexp
	reMili         *regexp.Regexp
	reSec          *regexp.Regexp
	reTsMin        *regexp.Regexp
	reTsHour       *regexp.Regexp
	reTsDay        *regexp.Regexp
}

func NewFilterApplyTookTooLong(aggregator string) *FilterApplyTookTooLong {
	var filter FilterApplyTookTooLong

	filter.Name = "ApplyTookTooLong"
	filter.GroupBy = aggregator
	filter.Group = make(map[string]*BucketGroup)

	filter.lineFilter = "apply request took too long"
	filter.reLineSplitter, _ = regexp.Compile(`^\d+-\d+-\d+T\d+:\d+:\d+.\d+Z `)
	filter.reMili, _ = regexp.Compile("([0-9]+.[0-9]+)ms")
	filter.reSec, _ = regexp.Compile("([0-9]+.[0-9]+)s")
	filter.reTsMin, _ = regexp.Compile(`^(\d+-\d+-\d+T\d+:\d+):\d+.\d+Z`)
	filter.reTsHour, _ = regexp.Compile(`^(\d+-\d+-\d+T\d+):\d+:\d+.\d+Z`)
	filter.reTsDay, _ = regexp.Compile(`^(\d+-\d+-\d+)T\d+:\d+:\d+.\d+Z`)

	return &filter
}

func (f *FilterApplyTookTooLong) ProcessLine(line string) {

	// filter by required filter
	if !strings.Contains(line, f.lineFilter) {
		return
	}

	// split timestamp
	split := f.reLineSplitter.Split(line, -1)
	if len(split) < 1 {
		return
	}

	// parse json
	lineParsed := LogPayloadETCD{}
	json.Unmarshal([]byte(split[1]), &lineParsed)

	if match := f.reMili.MatchString(lineParsed.Took); match { // Extract milisseconds
		matches := f.reMili.FindStringSubmatch(lineParsed.Took)
		if len(matches) == 2 {
			if v, err := strconv.ParseFloat(matches[1], 64); err == nil {
				f.insertBucket(v, lineParsed.Timestamp)
			}
		}
	} else if match := f.reSec.MatchString(lineParsed.Took); match { // Extract seconds
		matches := f.reSec.FindStringSubmatch(lineParsed.Took)
		if len(matches) == 2 {
			if v, err := strconv.ParseFloat(matches[1], 64); err == nil {
				v = v * 1000
				f.insertBucket(v, lineParsed.Timestamp)
			}
		}
	} else {
		fmt.Printf("No bucket for: %v\n", lineParsed.Took)
	}
}

func (f *FilterApplyTookTooLong) insertBucket(v float64, ts string) {
	var group *BucketGroup
	var aggrKey string

	if f.GroupBy == "hour" {
		aggrValue := "all"
		if match := f.reTsHour.MatchString(ts); match {
			matches := f.reTsHour.FindStringSubmatch(ts)
			aggrValue = matches[1]
		}
		aggrKey = aggrValue
	} else if f.GroupBy == "day" {
		aggrValue := "all"
		if match := f.reTsDay.MatchString(ts); match {
			matches := f.reTsDay.FindStringSubmatch(ts)
			aggrValue = matches[1]
		}
		aggrKey = aggrValue
	} else if f.GroupBy == "minute" || f.GroupBy == "min" {
		aggrValue := "all"
		if match := f.reTsMin.MatchString(ts); match {
			matches := f.reTsMin.FindStringSubmatch(ts)
			aggrValue = matches[1]
		}
		aggrKey = aggrValue
	} else {
		aggrKey = f.GroupBy
	}

	if _, ok := f.Group[aggrKey]; !ok {
		f.Group[aggrKey] = &BucketGroup{}
		group = f.Group[aggrKey]
		group.Bukets1s = NewBuckets(buckets1s())
		group.Bukets500ms = NewBuckets(buckets500ms())
	} else {
		group = f.Group[aggrKey]
	}

	b1s := group.Bukets1s
	b500ms := group.Bukets500ms

	switch {
	case v < 200:
		k := "low-200"
		b1s[k] = append(b1s[k], v)
		b500ms[k] = append(b500ms[k], v)

	case ((v >= 200) && (v < 300)):
		k := "200-300"
		b1s[k] = append(b1s[k], v)
		b500ms[k] = append(b500ms[k], v)

	case ((v >= 300) && (v < 400)):
		k := "300-400"
		b1s[k] = append(b1s[k], v)
		b500ms[k] = append(b500ms[k], v)

	case ((v >= 400) && (v < 500)):
		k := "400-500"

		b1s[k] = append(b1s[k], v)
		b500ms[k] = append(b500ms[k], v)
	case ((v >= 500) && (v < 600)):
		k := "500-600"
		b1s[k] = append(b1s[k], v)

		k = "500-inf"
		b500ms[k] = append(b500ms[k], v)

	case ((v >= 600) && (v < 700)):
		k := "600-700"
		b1s[k] = append(b1s[k], v)

		k = "500-inf"
		b500ms[k] = append(b500ms[k], v)
	case ((v >= 700) && (v < 800)):
		k := "700-800"
		b1s[k] = append(b1s[k], v)

		k = "500-inf"
		b500ms[k] = append(b500ms[k], v)

	case ((v >= 800) && (v < 900)):
		k := "800-900"
		b1s[k] = append(b1s[k], v)

		k = "500-inf"
		b500ms[k] = append(b500ms[k], v)

	case ((v >= 900) && (v < 1000)):
		k := "900-1s"
		b1s[k] = append(b1s[k], v)

		k = "500-inf"
		b500ms[k] = append(b500ms[k], v)

	case (v >= 1000):
		k := "1s-inf"
		b1s[k] = append(b1s[k], v)

		k = "500-inf"
		b500ms[k] = append(b500ms[k], v)

	default:
		k := "unkw"
		b1s[k] = append(b1s[k], v)
		b500ms[k] = append(b500ms[k], v)
	}
	k := "all"
	b1s[k] = append(b1s[k], v)
	b500ms[k] = append(b500ms[k], v)
}

func (f *FilterApplyTookTooLong) Show() {

	fmt.Printf("= Filter Name: %s =\n", f.Name)

	fmt.Printf("== Group by: %s ==\n", f.GroupBy)
	groups := make([]string, 0, len(f.Group))
	for k := range f.Group {
		groups = append(groups, k)
	}
	sort.Strings(groups)
	for _, gk := range groups {
		group := f.Group[gk]
		if gk != "all" {
			fmt.Printf("\n== %s ==\n", gk)
		}
		b1s := group.Bukets1s
		b500ms := group.Bukets500ms

		tbWriter := tabwriter.NewWriter(os.Stdout, 0, 8, 1, '\t', tabwriter.AlignRight)
		getBucketStr := func(k string) string {
			// v := b1s[k]
			countB1ms := len(b1s[k])
			countB1all := len(b1s["all"])
			perc := fmt.Sprintf("(%.3f %%)", (float64(countB1ms)/float64(countB1all))*100)
			if k == "all" {
				perc = ""
			}
			// fmt.Fprintf(tbWriter, "%s\t %d\t%s", k, countB1ms, perc)
			return fmt.Sprintf("%8.8s %6s %11.10s", k, fmt.Sprintf("%d", countB1ms), perc)
		}

		fmt.Println("=== Summary ===")
		fmt.Printf("%s\n", getBucketStr("all"))

		v500 := len(b500ms["500-inf"])
		perc500inf := (float64(v500) / float64(len(b500ms["all"]))) * 100
		fmt.Fprintf(tbWriter, "%8.8s %6s (%.3f %%)\n", ">500ms", fmt.Sprintf("%d", v500), perc500inf)
		fmt.Fprintf(tbWriter, "---\n")

		fmt.Println("=== Buckets (ms) ===")
		fmt.Fprintf(tbWriter, "%s | %s | %s\n", getBucketStr("200-300"), getBucketStr("600-700"), getBucketStr("1s-inf"))
		fmt.Fprintf(tbWriter, "%s | %s | %s\n", getBucketStr("300-400"), getBucketStr("700-800"), getBucketStr("unkw"))
		fmt.Fprintf(tbWriter, "%s | %s\n", getBucketStr("400-500"), getBucketStr("800-900"))
		fmt.Fprintf(tbWriter, "%s | %s\n", getBucketStr("500-600"), getBucketStr("900-1s"))
		fmt.Fprintf(tbWriter, "%s : %v\n", "unkw", b1s["unkw"])

		fmt.Println("=== Timers ===")
		// https://www.golangprograms.com/golang-statistics-package.html
		min, _ := stats.Min(b1s["all"])
		max, _ := stats.Max(b1s["all"])
		sum, _ := stats.Sum(b1s["all"])
		median, _ := stats.Median(b1s["all"])
		p90, _ := stats.Percentile(b1s["all"], 90)
		p99, _ := stats.Percentile(b1s["all"], 99)
		p999, _ := stats.Percentile(b1s["all"], 99.9)
		stddev, _ := stats.StandardDeviationPopulation(b1s["all"])
		qoutliers, _ := stats.QuartileOutliers(b1s["all"])

		fmt.Fprintf(tbWriter,
			"%6s \t: %17s\t| %10s \t: %.3f (ms)\n",
			"Count", fmt.Sprintf("%d", len(b1s["all"])),
			"P90", p90)
		fmt.Fprintf(tbWriter,
			"%6s \t: %12.3f (ms)\t| %10s \t: %f (ms)\n",
			"Min", min,
			"P99", p99)
		fmt.Fprintf(tbWriter,
			"%6s \t: %12.3f (ms)\t| %10s \t: %.3f (ms)\n",
			"Max", max,
			"P99.9", p999)
		fmt.Fprintf(tbWriter,
			"%6s \t: %12.3f (ms)\t| %10s \t: %.3f (ms)\n",
			"Sum", sum,
			"StdDev", stddev)
		fmt.Fprintf(tbWriter,
			"%6s \t: %12.3f (ms)\t| %10s \t: %+v\n",
			"Median", median,
			"Outliers", qoutliers)

		tbWriter.Flush()
	}
}
