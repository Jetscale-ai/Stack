package e2e

import (
	"fmt"
	"net/http"
	"os"
	"testing"
	"time"
)

// TestSystemHealth performs a basic connectivity check against the environment.
// It relies on the BASE_URL environment variable provided by Mage.
func TestSystemHealth(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Fatal("❌ BASE_URL environment variable not set. Are you running this via 'mage test'?")
	}

	fmt.Printf("🔍 Checking connectivity to: %s\n", baseURL)

	// Retry loop to allow for Ingress propagation or cold starts
	maxRetries := 10
	var lastErr error

	for i := 0; i < maxRetries; i++ {
		resp, err := http.Get(baseURL + "/docs") // Checking FastAPI docs as a generic heartbeat
		if err == nil {
			defer resp.Body.Close()
			if resp.StatusCode == 200 {
				fmt.Printf("✅ Success: %s is reachable (Status: 200)\n", baseURL)
				return
			}
			lastErr = fmt.Errorf("status code %d", resp.StatusCode)
		} else {
			lastErr = err
		}

		fmt.Printf("⏳ Attempt %d/%d failed (%v). Retrying in 2s...\n", i+1, maxRetries, lastErr)
		time.Sleep(2 * time.Second)
	}

	t.Fatalf("❌ Failed to reach system after %d attempts. Last error: %v", maxRetries, lastErr)
}
