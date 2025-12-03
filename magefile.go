//go:build mage

package main

import (
	"fmt"
	"net"
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
// VALIDATION (Structural Integrity)
// -----------------------------------------------------------------------------

type Validate mg.Namespace

// Envs runs 'helm template' against all environment configurations.
// This proves that values.yaml + templates = Valid Kubernetes YAML.
// It does NOT require a cluster.
func (Validate) Envs() error {
	envs := []string{"live", "preview"}
	
	fmt.Println("🔍 Validating Environment Configurations...")
	
	// Ensure dependencies are ready (requires OCI access or local file://)
	// We try dependency build, but ignore error if OCI is not yet published,
	// assuming templates might still render if dependencies are conditional.
	// For strict validation, dependencies must exist.
	fmt.Println("   > helm dependency build charts/app")
	exec.Command("helm", "dependency", "build", "charts/app").Run()

	for _, env := range envs {
		valuesFile := fmt.Sprintf("envs/%s/values.yaml", env)
		fmt.Printf("   > Checking %s...", valuesFile)
		
		// Run Helm Template
		// --dry-run: simulate install
		// --debug: print generated manifest on failure
		cmd := exec.Command("helm", "template", "jetscale-stack", "charts/app", 
			"--values", valuesFile,
			"--debug")
		
		if out, err := cmd.CombinedOutput(); err != nil {
			fmt.Printf("❌ FAILED\n")
			fmt.Println(string(out))
			return fmt.Errorf("validation failed for %s", env)
		}
		fmt.Printf("✅ Valid Syntax\n")
	}
	return nil
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

	cleanup := func() {
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
	}

	// ✅ VIGOR: Active verification loop instead of blind sleep
	fmt.Printf("   > Waiting for connection to localhost:%d...\n", localPort)
	maxRetries := 30 // 15 seconds total
	for i := 0; i < maxRetries; i++ {
		timeout := 500 * time.Millisecond
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("localhost:%d", localPort), timeout)
		if err == nil {
			conn.Close()
			fmt.Println("   > Connection established.")
			return cleanup, localPort, nil
		}
		
		// If kubectl exited, stop immediately
		if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
			return nil, 0, fmt.Errorf("kubectl port-forward exited unexpectedly")
		}
		
		time.Sleep(500 * time.Millisecond)
	}
	
	cleanup()
	return nil, 0, fmt.Errorf("timed out waiting for port-forward to open")
}
