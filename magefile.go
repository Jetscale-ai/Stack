//go:build mage

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/magefile/mage/mg"
)

var Default = Dev

// -----------------------------------------------------------------------------
// AUTH (Local Dev QoL)
// -----------------------------------------------------------------------------

// loadDotEnvIfPresent loads KEY=VALUE pairs from a local .env file into the
// current process environment (without overriding variables that are already set).
//
// This repo is public: `.env` must remain gitignored and developer-managed.
func loadDotEnvIfPresent(path string) (bool, error) {
	fi, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if fi.IsDir() {
		return false, fmt.Errorf("%s is a directory, expected a file", path)
	}

	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	// Allow long lines (tokens can be long).
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")

		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		if k == "" {
			continue
		}

		// Strip wrapping quotes.
		if len(v) >= 2 {
			if (v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'') {
				v = v[1 : len(v)-1]
			}
		}

		if os.Getenv(k) != "" {
			// Respect already-exported env vars.
			continue
		}
		_ = os.Setenv(k, v)
	}
	if err := sc.Err(); err != nil {
		return true, err
	}
	return true, nil
}

// ensureHelmGhcrLogin logs Helm into GHCR if a GitHub token is present.
//
// This makes `mage validate:envs` work out-of-the-box for local devs who keep
// a `GITHUB_TOKEN` in their (gitignored) .env.
//
// If no token is present, we do nothing and fall back to whatever auth Helm
// already has (or to failing on private OCI deps).
func ensureHelmGhcrLogin() error {
	token := strings.TrimSpace(os.Getenv("GITHUB_TOKEN"))
	if token == "" {
		// Common alt name (CI setups)
		token = strings.TrimSpace(os.Getenv("GH_TOKEN"))
	}
	if token == "" {
		return nil
	}

	username := strings.TrimSpace(os.Getenv("GITHUB_USER"))
	if username == "" {
		// Derive username from token (no secrets printed).
		req, err := http.NewRequest("GET", "https://api.github.com/user", nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "token "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			body, _ := io.ReadAll(resp.Body)
			return fmt.Errorf("failed to resolve GitHub username from token: %s: %s", resp.Status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Login string `json:"login"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
			return err
		}
		username = payload.Login
	}

	if username == "" {
		return fmt.Errorf("could not determine GitHub username for GHCR login; set GITHUB_USER")
	}

	cmd := exec.Command("helm", "registry", "login", "ghcr.io", "--username", username, "--password-stdin")
	cmd.Stdin = bytes.NewBufferString(token)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

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

	// Local Dev QoL: load `.env` if present so devs don't need to export vars in their shell.
	// (Safe: `.env` should be gitignored; we never print secrets.)
	_, _ = loadDotEnvIfPresent(".env")

	// Optional QoL: if a GitHub token is available, authenticate Helm to GHCR so
	// private OCI chart deps can be pulled without manual login steps.
	_ = ensureHelmGhcrLogin()

	// Ensure dependencies are ready (requires OCI access or local file://)
	fmt.Println("   > helm dependency build charts/app")
	depCmd := exec.Command("helm", "dependency", "build", "charts/app")
	if out, err := depCmd.CombinedOutput(); err != nil {
		// Provide a meaningful local-dev error when GHCR auth is missing.
		msg := string(out)
		if strings.Contains(msg, "denied") || strings.Contains(msg, "UNAUTHORIZED") || strings.Contains(msg, "403") {
			abs, _ := filepath.Abs(".env")
			return fmt.Errorf(
				"helm dependency build failed due to GHCR auth.\n\n"+
					"Fix (Local Dev): create a gitignored .env with:\n"+
					"  GITHUB_TOKEN=<token with read:packages>\n"+
					"(optional) GITHUB_USER=<github username>\n\n"+
					"Then re-run: mage validate:envs\n\n"+
					".env path: %s\n\n"+
					"helm output:\n%s",
				abs,
				msg,
			)
		}
		// Generic failure
		return fmt.Errorf("helm dependency build failed:\n%s", msg)
	}

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

	// ✅ VIGOR: Explicitly wait for the deployment to be available before port-forwarding.
	// This prevents kubectl port-forward from connecting to a crashing pod.
	fmt.Println("⏳ Waiting for Backend Deployment to be Available...")
	waitCmd := exec.Command("kubectl", "wait",
		"--namespace", "jetscale-ci",
		"--for=condition=available",
		"deployment/jetscale-stack-ci-backend-api",
		"--timeout=120s")
	waitCmd.Stdout = os.Stdout
	waitCmd.Stderr = os.Stderr
	if err := waitCmd.Run(); err != nil {
		return fmt.Errorf("backend deployment failed to become available: %w", err)
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
	// Live console hostname (see envs/live/values.yaml)
	host := "console.jetscale.ai"
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

	// Active verification loop
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
