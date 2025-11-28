//go:build mage

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/magefile/mage/mg"
)

var Default = Dev

// -----------------------------------------------------------------------------
// LOCAL DEVELOPMENT (The Inner Loop)
// -----------------------------------------------------------------------------

func Dev() error {
	fmt.Println("🚀 Starting Tilt (Inner Loop)...")
	cmd := exec.Command("tilt", "up")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func Clean() error {
	fmt.Println("🧹 Cleaning up...")
	exec.Command("kubectl", "delete", "ns", "jetscale-test-local", "--ignore-not-found").Run()
	cmd := exec.Command("tilt", "down")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// -----------------------------------------------------------------------------
// TESTING NAMESPACE
// -----------------------------------------------------------------------------

type Test mg.Namespace

// LocalDev runs a quick smoke test against the running Tilt environment.
func (Test) LocalDev() error {
	fmt.Println("🧪 [E2E] Target: Local Dev (Tilt)")
	return runTestRunner("http://localhost:8000")
}

// LocalE2E runs high-fidelity tests in Kind using locally built Alpine images.
func (Test) LocalE2E() error {
	fmt.Println("🧪 [E2E] Target: Kind Local (Alpine E2E)")
	
	if err := runSkaffoldDeploy("local-kind", "jetscale-test-local"); err != nil {
		return err
	}

	stopPF, localPort, err := startPortForward("jetscale-test-local", "svc/jetscale-stack-test-backend-api", 8000)
	if err != nil {
		return fmt.Errorf("failed to port-forward: %w", err)
	}
	defer stopPF()

	return runTestRunner(fmt.Sprintf("http://localhost:%d", localPort))
}

// CI runs E2E tests in Kind using CI-built artifacts.
func (Test) CI() error {
	fmt.Println("🧪 [E2E] Target: Kind CI (Artifacts)")
	
	if err := runSkaffoldDeploy("ci-kind", "jetscale-ci"); err != nil {
		return err
	}

	stopPF, localPort, err := startPortForward("jetscale-ci", "svc/jetscale-stack-ci-backend-api", 8000)
	if err != nil {
		return fmt.Errorf("failed to port-forward: %w", err)
	}
	defer stopPF()

	return runTestRunner(fmt.Sprintf("http://localhost:%d", localPort))
}

func (Test) Live() error {
	fmt.Println("🔥 [E2E] Target: EKS Live (Verification)")
	host := "app.jetscale.ai"
	return runTestRunner(fmt.Sprintf("https://%s", host))
}

// -----------------------------------------------------------------------------
// HELPERS
// -----------------------------------------------------------------------------

func runSkaffoldDeploy(profile, namespace string, extraArgs ...string) error {
	args := []string{"run", "-p", profile}
	if namespace != "" {
		args = append(args, "--namespace", namespace)
	}
	args = append(args, extraArgs...)

	fmt.Printf("   > skaffold %s\n", strings.Join(args, " "))

	deploy := exec.Command("skaffold", args...)
	deploy.Stdout = os.Stdout
	deploy.Stderr = os.Stderr
	return deploy.Run()
}

func runTestRunner(url string) error {
	fmt.Printf("   > Running Go E2E Suite against %s\n", url)
	os.Setenv("BASE_URL", url)
	cmd := exec.Command("go", "test", "-v", ".")
	cmd.Dir = "tests/e2e"
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func startPortForward(ns, resource string, targetPort int) (func(), int, error) {
	localPort := 9090 
	fmt.Printf("   > Port-forwarding %s %s -> localhost:%d\n", ns, resource, localPort)
	
	cmd := exec.Command("kubectl", "port-forward", "-n", ns, resource, fmt.Sprintf("%d:%d", localPort, targetPort))
	
	// Capture stderr to help debug crashes
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return nil, 0, err
	}
	
	// Wait for connection to establish
	time.Sleep(3 * time.Second)

	// Check if process died during sleep
	if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
		return nil, 0, fmt.Errorf("kubectl port-forward exited unexpectedly (check target port %d existence)", targetPort)
	}

	cleanup := func() {
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
	}
	return cleanup, localPort, nil
}
