//go:build mage

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/magefile/mage/mg"
)

// Default target to run when 'mage' is called without arguments.
var Default = Dev

// -----------------------------------------------------------------------------
// LOCAL DEVELOPMENT (The Inner Loop)
// -----------------------------------------------------------------------------

// Dev starts the high-fidelity local development environment via Tilt.
func Dev() error {
	fmt.Println("🚀 Starting Tilt (Inner Loop)...")
	cmd := exec.Command("tilt", "up")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// Clean tears down the local Kind cluster and removes artifacts.
func Clean() error {
	fmt.Println("🧹 Cleaning up...")
	cmd := exec.Command("tilt", "down")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// -----------------------------------------------------------------------------
// CI & INTEGRATION (The Outer Loop)
// -----------------------------------------------------------------------------

// CI runs the full CI pipeline locally using Skaffold + Kind.
func CI() error {
	fmt.Println("🤖 Running CI Pipeline (Skaffold profile: ci-kind)...")
	fmt.Println("   - Building images...")
	fmt.Println("   - Creating ephemeral Kind cluster...")
	fmt.Println("   - Running E2E tests...")
	return runSkaffold("ci-kind", "jetscale-ci", "http://localhost:8000")
}

// -----------------------------------------------------------------------------
// TESTING NAMESPACE
// -----------------------------------------------------------------------------

// Test provides granular targets for each environment loop.
type Test mg.Namespace

// Local runs E2E tests in Kind using locally built images (no push).
func (Test) Local() error {
	fmt.Println("🧪 [E2E] Target: Kind Local (Local Images)")
	fmt.Println("   - Strategy: Build -> Load into Kind -> Test")
	return runSkaffold("local-kind", "jetscale-local", "http://localhost:8000")
}

// CI runs E2E tests in Kind using CI-built artifacts.
func (Test) CI() error {
	fmt.Println("🧪 [E2E] Target: Kind CI (Artifacts)")
	fmt.Println("   - Strategy: Build -> Push -> Deploy -> Test")
	return runSkaffold("ci-kind", "jetscale-ci", "http://localhost:8000")
}

// Preview runs E2E tests against an ephemeral EKS namespace (Pre-Merge).
func (Test) Preview() error {
	fmt.Println("🧪 [E2E] Target: EKS Preview (Ephemeral)")
	namespace, host := getPreviewTarget()
	fmt.Printf("   - Namespace: %s\n", namespace)
	fmt.Printf("   - Host: %s\n", host)
	setHost := fmt.Sprintf("--set=ingress.host=%s", host)
	return runSkaffold("preview", namespace, fmt.Sprintf("https://%s", host), setHost)
}

// Live runs smoke tests against the live environment.
func (Test) Live() error {
	fmt.Println("🔥 [E2E] Target: EKS Live (Verification)")
	fmt.Println("   ⚠️  running in VERIFICATION mode (No Deploy)")
	host := "app.jetscale.ai"
	return runTestRunner(fmt.Sprintf("https://%s", host))
}

// -----------------------------------------------------------------------------
// LIVE & RELEASE
// -----------------------------------------------------------------------------

// Deploy triggers a deployment to a specified environment.
// Args: env (preview|live)
func Deploy(env string) error {
	fmt.Printf("🚢 Deploying Stack to environment: [%s]\n", env)
	fmt.Printf("   - Profile: %s\n", env)
	fmt.Println("⚠️  (Not yet implemented: will wrap Helm/Skaffold)")
	return nil
}

// -----------------------------------------------------------------------------
// HELPERS
// -----------------------------------------------------------------------------

func runSkaffold(profile, namespace, baseURL string, extraArgs ...string) error {
	args := []string{"run", "-p", profile}
	if namespace != "" {
		args = append(args, "--namespace", namespace)
	}
	args = append(args, extraArgs...)

	fmt.Printf("   > skaffold %s\n", strings.Join(args, " "))

	deploy := exec.Command("skaffold", args...)
	deploy.Stdout = os.Stdout
	deploy.Stderr = os.Stderr
	if err := deploy.Run(); err != nil {
		return fmt.Errorf("deployment failed: %w", err)
	}

	return runTestRunner(baseURL)
}

func runTestRunner(url string) error {
	fmt.Printf("   > Running Go E2E Suite against %s\n", url)
	os.Setenv("BASE_URL", url)
	// We use 'go test -v' to see the logs
	cmd := exec.Command("go", "test", "-v", "./tests/e2e")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func getPreviewTarget() (string, string) {
	if pr := os.Getenv("PR_NUMBER"); pr != "" {
		return fmt.Sprintf("jetscale-pr-%s", pr), fmt.Sprintf("pr-%s.app.jetscale.ai", pr)
	}

	user := os.Getenv("USER")
	if user == "" {
		user = "local-dev"
	}

	return fmt.Sprintf("jetscale-preview-%s", user), fmt.Sprintf("preview-%s.app.jetscale.ai", user)
}
