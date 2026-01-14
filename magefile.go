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

// ensureK8sGhcrPullSecret ensures the Kind cluster can pull GHCR images by creating a docker-registry
// secret in the given namespace and patching the default ServiceAccount to reference it.
//
// This mirrors the CI workflow behavior (see `.github/workflows/pipeline.yaml`).
//
// Required env:
// - GITHUB_TOKEN (or GH_TOKEN): token with `read:packages`
// Optional env:
// - GITHUB_USER: username (if unset, we derive it from the token)
func ensureK8sGhcrPullSecret(namespace, secretName string) error {
	token := strings.TrimSpace(os.Getenv("GITHUB_TOKEN"))
	if token == "" {
		token = strings.TrimSpace(os.Getenv("GH_TOKEN"))
	}
	if token == "" {
		// No token: can't create pull secret. Caller decides whether to fail or proceed.
		return nil
	}

	username := strings.TrimSpace(os.Getenv("GITHUB_USER"))
	if username == "" {
		// Reuse the same GitHub API lookup as Helm login.
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
		return fmt.Errorf("could not determine GitHub username for GHCR pull secret; set GITHUB_USER")
	}

	fmt.Printf("🔐 Ensuring GHCR pull secret %q in namespace %q...\n", secretName, namespace)

	// Namespace (idempotent)
	nsCreate := exec.Command("kubectl", "create", "ns", namespace, "--dry-run=client", "-o", "yaml")
	nsYAML, err := nsCreate.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("failed to create namespace yaml: %s", strings.TrimSpace(string(ee.Stderr)))
		}
		return err
	}
	nsApply := exec.Command("kubectl", "apply", "-f", "-")
	nsApply.Stdin = bytes.NewReader(nsYAML)
	nsApply.Stdout = os.Stdout
	nsApply.Stderr = os.Stderr
	if err := nsApply.Run(); err != nil {
		return err
	}

	// Create secret via kubectl dry-run+apply (idempotent)
	create := exec.Command("kubectl", "create", "secret", "docker-registry", secretName,
		"--docker-server=ghcr.io",
		"--docker-username="+username,
		"--docker-password="+token,
		"--namespace="+namespace,
		"--dry-run=client", "-o", "yaml",
	)
	out, err := create.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("failed to create docker-registry secret yaml: %s", strings.TrimSpace(string(ee.Stderr)))
		}
		return err
	}
	apply := exec.Command("kubectl", "apply", "-f", "-")
	apply.Stdin = bytes.NewReader(out)
	apply.Stdout = os.Stdout
	apply.Stderr = os.Stderr
	if err := apply.Run(); err != nil {
		return err
	}

	// Patch default SA so pods can pull
	patch := exec.Command("kubectl", "patch", "serviceaccount", "default",
		"-n", namespace,
		"-p", fmt.Sprintf(`{"imagePullSecrets":[{"name":"%s"}]}`, secretName),
	)
	patch.Stdout = os.Stdout
	patch.Stderr = os.Stderr
	return patch.Run()
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
//
// USAGE: mage validate:envs <cloudName>
// Examples: mage validate:envs aws | mage validate:envs gcp | mage validate:envs azure
//
// The cloudName parameter specifies which cloud provider values file to use (envs/<cloudName>.yaml)
func (Validate) Envs(cloudName string) error {
	fmt.Println("🔍 Validating Environment Configurations...")

	// Validate cloudName is provided
	if cloudName == "" {
		return fmt.Errorf(
			"cloudName argument is required.\n\n" +
				"Usage: mage validate:envs <cloudName>\n" +
				"Examples:\n" +
				"  mage validate:envs aws\n" +
				"  mage validate:envs gcp\n" +
				"  mage validate:envs azure\n\n" +
				"This will use the cloud-specific values file: envs/<cloudName>.yaml",
		)
	}

	// Local Dev QoL: load `.env` if present so devs don't need to export vars in their shell.
	// (Safe: `.env` should be gitignored; we never print secrets.)
	_, _ = loadDotEnvIfPresent(".env")

	// Optional QoL: if a GitHub token is available, authenticate Helm to GHCR so
	// private OCI chart deps can be pulled without manual login steps.
	_ = ensureHelmGhcrLogin()

	// Ensure dependencies are updated (requires OCI access or local file://)
	fmt.Println("   > helm dependency update charts/jetscale")
	depUpCmd := exec.Command("helm", "dependency", "update", "charts/jetscale")
	if out, err := depUpCmd.CombinedOutput(); err != nil {
		msg := string(out)
		return fmt.Errorf("helm dependency update failed:\n%s", msg)
	}

	// Ensure dependencies are ready (requires OCI access or local file://)
	fmt.Println("   > helm dependency build charts/jetscale")
	depCmd := exec.Command("helm", "dependency", "build", "charts/jetscale")
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
		
	// Check for cloud-specific values file
	cloudValuesFile := filepath.Join("envs", cloudName+".yaml")
	if _, err := os.Stat(cloudValuesFile); err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf(
				"cloud values file not found: %s\n\n"+
				"Please ensure the file exists for cloud provider: %s\n"+
				"Expected file: envs/%s.yaml",
				cloudValuesFile, cloudName, cloudName,
			)
		}
		return fmt.Errorf("failed to check cloud values file: %w", err)
	}
	fmt.Printf("   > Using cloud values file: %s\n", cloudValuesFile)
	
	// Discover all YAML files in envs/ subdirectories
	var valuesFiles []string
	envsDir := "envs"
	
	err := filepath.Walk(envsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		// Skip directories and non-YAML files
		if info.IsDir() {
			return nil
		}
		// Match .yaml and .yml files
		if strings.HasSuffix(info.Name(), ".yaml") || strings.HasSuffix(info.Name(), ".yml") {
			// Skip default.yaml and envs/ top-level files
			if strings.TrimSuffix(info.Name(), ".yaml") != "default" && filepath.Dir(path) != envsDir {
				valuesFiles = append(valuesFiles, path)
			}
		}
		return nil
	})
	
	if err != nil {
		return fmt.Errorf("failed to discover environment files: %w", err)
	}
	
	if len(valuesFiles) == 0 {
		return fmt.Errorf("no YAML files found in %s directory", envsDir)
	}
	
	fmt.Printf("   > Found %d environment configuration(s)\n", len(valuesFiles))
	
	// Validate each discovered values file
	for _, valuesFile := range valuesFiles {
		fmt.Printf("   > Checking %s\n", valuesFile)

		// Run Helm Template
		// --dry-run: simulate install
		// --debug: print generated manifest on failure
		args := []string{"template", "jetscale", "charts/jetscale"}
		var usedFiles []string
		
		// Add cloud-specific values file
		args = append(args, "--values", cloudValuesFile)
		usedFiles = append(usedFiles, cloudValuesFile)
		
		// Check for default.yaml or default.yml in the same directory as valuesFile
		envDir := filepath.Dir(valuesFile)
		var defaultValuesFile string
		for _, defaultName := range []string{"default.yaml", "default.yml"} {
			defaultPath := filepath.Join(envDir, defaultName)
			if _, err := os.Stat(defaultPath); err == nil {
				defaultValuesFile = defaultPath
				break
			}
		}
		if defaultValuesFile != "" {
			args = append(args, "--values", defaultValuesFile)
			usedFiles = append(usedFiles, defaultValuesFile)
		}
		
		// Add environment-specific values file
		args = append(args, "--values", valuesFile, "--debug")
		usedFiles = append(usedFiles, valuesFile)
		
		// Print the files being used in order
		fmt.Printf("     Values files (in order): ")
		for i, f := range usedFiles {
			if i > 0 {
				fmt.Printf(" → ")
			}
			fmt.Printf("%s", f)
		}
		fmt.Println()
		
		cmd := exec.Command("helm", args...)

		if out, err := cmd.CombinedOutput(); err != nil {
			fmt.Printf("     ❌ FAILED\n")
			fmt.Println(string(out))
			return fmt.Errorf("validation failed for %s", valuesFile)
		}
		fmt.Printf("     ✅ Valid Syntax\n")
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

	stopPF, localPort, err := startPortForward("jetscale-test-local", "svc/jetscale-test-backend-api", 8000)
	if err != nil {
		return fmt.Errorf("failed to port-forward: %w", err)
	}
	defer stopPF()

	return runTestRunner(fmt.Sprintf("http://localhost:%d", localPort))
}

// CI runs E2E tests in Kind using CI-built artifacts.
func (Test) CI() error {
	fmt.Println("🧪 [E2E] Target: Kind CI (Artifacts)")

	// Local parity: CI pipeline provisions the regcred secret before running mage test:ci.
	// For local runs, do the same if a GH token is available.
	_, _ = loadDotEnvIfPresent(".env")
	_ = ensureK8sGhcrPullSecret("jetscale-ci", "regcred")

	if err := runSkaffoldDeploy("ci-kind", "jetscale-ci"); err != nil {
		return err
	}

	// ✅ VIGOR: Explicitly wait for the deployment to be available before port-forwarding.
	// This prevents kubectl port-forward from connecting to a crashing pod.
	fmt.Println("⏳ Waiting for Backend Deployment to be Available...")
	waitCmd := exec.Command("kubectl", "wait",
		"--namespace", "jetscale-ci",
		"--for=condition=available",
		"deployment/jetscale-ci-backend-api",
		"--timeout=120s")
	waitCmd.Stdout = os.Stdout
	waitCmd.Stderr = os.Stderr
	if err := waitCmd.Run(); err != nil {
		return fmt.Errorf("backend deployment failed to become available: %w", err)
	}

	stopPF, localPort, err := startPortForward("jetscale-ci", "svc/jetscale-ci-backend-api", 8000)
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
