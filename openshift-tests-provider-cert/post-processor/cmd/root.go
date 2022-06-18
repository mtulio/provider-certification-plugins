/*
Copyright 2022 the Sonobuoy Project contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package cmd

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/pkg/errors"
	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	ph "github.com/vmware-tanzu/sonobuoy-plugins/plugin-helper"
	"gopkg.in/yaml.v2"

	"github.com/vmware-tanzu/sonobuoy/pkg/client/results"
	"github.com/vmware-tanzu/sonobuoy/pkg/plugin/driver/job"
	"github.com/vmware-tanzu/sonobuoy/pkg/plugin/manifest"
)

const (
	donefile = "done"
)

func GetDoneFilePath() string {
	return filepath.Join(ph.GetResultsDir(), donefile)
}

func DoneFileExists() bool {
	if _, err := os.Stat(GetDoneFilePath()); err == nil {
		return true
	}
	return false
}

func RemoveDoneFile() error {
	logrus.Trace(">><< Removing DoneFile")
	if err := os.Remove(GetDoneFilePath()); err != nil {
		logrus.Errorf("Failed to remove donefile; postprocessing may end in race: %v", err)
	}
	return nil
}

func CreateDoneFileFake() error {
	logrus.Trace(">><< Creating DoneFile")
	fd, err := os.Create(GetDoneFilePath())
	if err != nil {
		msg := fmt.Sprintf("Failed to create donefile; postprocessing may end in race: %v", err)
		// logrus.Errorf(msg)
		return fmt.Errorf(msg)
	}
	defer fd.Close()
	return nil
}

// rootCmd represents the base command when called without any subcommands
func getRootCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "sonobuoy-post",
		Short: "Post-processor for Sonobuoy plugins",
		PreRunE: func(cmd *cobra.Command, args []string) error {
			return waitForDone()
		},
		RunE: func(cmd *cobra.Command, args []string) error {

			// Creating a ticker to tell the worker to wait the processing, regardless the total time.
			// Default is 5s and is impacting in Data race
			logrus.Trace(">><< Starting Done Control file watcher")
			ticker := time.NewTicker(1 * time.Second)
			done := make(chan bool)
			go func() {
				for {
					select {
					case <-done:
						return
					case t := <-ticker.C:
						fmt.Println("Checking", t)
						var err error
						if DoneFileExists() {
							err = RemoveDoneFile()
						} else {
							err = CreateDoneFileFake()
						}
						if err != nil {
							logrus.Errorf("%s", err)
						}
					}
				}
			}()

			logrus.Trace(">><< A")
			dir := os.Getenv("SONOBUOY_RESULTS_DIR")

			// First we have to convert to the common yaml format.
			// WIP just assuming junit and hardcoding the conversion
			pName := "tmp-postprocessing-name"
			format := "junit"

			// TODO(johnschnake): I think we should be able to call into a higher level function to process different
			// formats and automatically be more robust. TBD. It needs to just know the format the plugin was providing
			// here, but we'd ultimately end up sending out manual results.
			m := manifest.Manifest{
				SonobuoyConfig: manifest.SonobuoyConfig{
					PluginName:   pName,
					Driver:       "job",
					ResultFormat: format,
				},
			}
			p := job.NewPlugin(m, "", "", "", "", nil)
			logrus.Trace(">><< B")
			items, err := results.ProcessDir(p, "", dir, results.JunitProcessFile, results.FileOrExtension([]string{}, ".xml"))
			if err != nil {
				logrus.Errorf("Error processing plugin %v: %v", p.GetName(), err)
				return err
			}
			logrus.Trace(">><< C")
			if len(items) == 0 {
				return errors.New("did not get any results when processing results")
			}
			logrus.Trace(">><< D")
			// Save existing yaml so we can apply ytt transform to it.
			output := results.Item{
				Name: p.GetName(),
				Metadata: map[string]string{
					results.MetadataTypeKey: results.MetadataTypeSummary,
				},
			}

			logrus.Trace(">><< 0")
			output.Items = append(output.Items, items...)
			output.Status = results.AggregateStatus(output.Items...)
			logrus.Trace(">><< 1")
			//logrus.Trace(output)
			SaveYAML(output)
			logrus.Trace(">><< 2")
			logrus.Trace(">><< 2A copy")
			// cp := exec.Command("cp", "-rf",
			// 	fmt.Sprintf("%v/sonobuoy_results.yaml", ph.GetResultsDir()),
			// 	fmt.Sprintf("%v/sonobuoy_results2.yaml", ph.GetResultsDir()))
			// _, err = cp.CombinedOutput()
			// if err != nil {
			// 	logrus.Trace(">><< 2A.err")
			// 	logrus.Error(err)
			// 	return err
			// }
			// Now shell out to ytt.
			c := exec.Command("/usr/bin/ytt",
				"--dangerous-allow-all-symlink-destinations",
				fmt.Sprintf("-f=%v/sonobuoy_results.yaml", ph.GetResultsDir()),
				fmt.Sprintf("-f=%v/ytt-transform-commentFailed.yaml", os.Getenv("SONOBUOY_CONFIG_DIR")),
				fmt.Sprintf("--output-files=%v", ph.GetResultsDir()))

			logrus.Trace(">><< 3")
			b, err := c.CombinedOutput()
			logrus.Trace(">><< 4")
			if err != nil {
				logrus.Trace(">><< 4.1")
				logrus.Trace(string(b))
				logrus.Error(err)
				return err
			}
			logrus.Trace(">><< 5")
			logrus.Trace(string(b))

			logrus.Trace(">><< 6")
			// err = os.Chmod(fmt.Sprintf("%v/transformed", ph.GetResultsDir()), 0755)
			// logrus.Trace(">><< 6A")
			// if err != nil {
			// 	//log.Fatal(err)
			// 	logrus.Trace(">><< 6.err1")
			// 	logrus.Error(err)
			// }
			// err = os.Chmod(fmt.Sprintf("%v/sonobuoy_results.yaml", ph.GetResultsDir()), 0644)
			// logrus.Trace(">><< 6B")
			// if err != nil {
			// 	//log.Fatal(err)
			// 	logrus.Trace(">><< 6.err2")
			// 	logrus.Error(err)
			// }
			// logrus.Trace(">><< 6C")
			// chmod := exec.Command("chmod", "-R", "0755", ph.GetResultsDir())
			// _, err = chmod.CombinedOutput()
			// if err != nil {
			// 	logrus.Trace(">><< 6C.err")
			// 	logrus.Error(err)
			// 	return err
			// }
			// ls := exec.Command("ls", "-R", fmt.Sprintf("%v", ph.GetResultsDir()))
			// lsO, err := ls.CombinedOutput()
			// if err != nil {
			// 	logrus.Trace(">><< 6C.err")
			// 	logrus.Trace(string(lsO))
			// 	logrus.Error(err)
			// 	return err
			// }
			// logrus.Trace(string(lsO))

			logrus.Trace(">><< 7 > Stopping the Ticker")
			ticker.Stop()
			done <- true
			logrus.Trace("Done with processing >><<")
			if DoneFileExists() {
				err = RemoveDoneFile()
			}
			return nil
		},
	}
}

func getResultsFileName() string {
	return filepath.Join(os.Getenv("SONOBUOY_RESULTS_DIR"), "sonobuoy_results.yaml")
}

func SaveYAML(item results.Item) error {
	logrus.Trace(">><< SaveYAML() 1")
	resultsFile := getResultsFileName()
	if err := os.MkdirAll(filepath.Dir(resultsFile), 0755); err != nil {
		return errors.Wrap(err, "error creating plugin directory")
	}
	logrus.Trace(">><< SaveYAML() 2")
	outfile, err := os.Create(resultsFile)
	if err != nil {
		logrus.Trace(">><< SaveYAML() 2.1")
		return errors.Wrap(err, "error creating results file")
	}
	logrus.Trace(">><< SaveYAML() 3")
	defer outfile.Close()

	logrus.Trace(">><< SaveYAML() 4")
	enc := yaml.NewEncoder(outfile)
	logrus.Trace(">><< SaveYAML() 5")
	defer enc.Close()
	logrus.Trace(">><< SaveYAML() 6")
	err = enc.Encode(item)
	logrus.Trace(">><< SaveYAML() 7")
	return errors.Wrap(err, "error writing to results file")
}

func waitForDone() error {
	logrus.WithField("waitfile", donefile).Info("Waiting for waitfile")
	ticker := time.NewTicker(time.Duration(1) * time.Second)
	donefilePath := filepath.Join(ph.GetResultsDir(), donefile)

	for {
		select {
		case <-ticker.C:
			if resultFile, err := ioutil.ReadFile(donefilePath); err == nil {
				resultFile = bytes.TrimSpace(resultFile)
				logrus.WithField("resultFile", string(resultFile)).Info("Detected done file, continuing with post-processing...")
				if err := os.Remove(donefilePath); err != nil {
					logrus.Errorf("Failed to remove donefile; postprocessing may end in race: %v", err)
				}
				return nil
			}
		}
	}
}

// Execute adds all child commands to the root command and sets flags appropriately.
// This is called by main.main(). It only needs to happen once to the rootCmd.
func Execute() {
	logrus.SetLevel(logrus.TraceLevel)
	err := getRootCmd().Execute()
	if err != nil {
		os.Exit(1)
	}
}
