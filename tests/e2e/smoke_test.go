package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

var httpTransport = &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	ForceAttemptHTTP2:     true,
	MaxIdleConns:          100,
	MaxIdleConnsPerHost:   20,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   10 * time.Second,
	ExpectContinueTimeout: 1 * time.Second,
}

var httpClient = &http.Client{
	Timeout:   10 * time.Second,
	Transport: httpTransport,
}

func drainAndClose(body io.ReadCloser) {
	_, _ = io.Copy(io.Discard, body)
	_ = body.Close()
}

// TestSystemHealth performs comprehensive smoke tests against the deployed environment.
// It relies on the BASE_URL environment variable provided by Mage.
func TestSystemHealth(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Fatal("❌ BASE_URL environment variable not set. Are you running this via 'mage test'?")
	}

	fmt.Printf("🔍 Checking connectivity to: %s\n", baseURL)

	// Basic connectivity check first
	maxRetries := 10
	var lastErr error

	for i := 0; i < maxRetries; i++ {
		// Keep this as generic as possible: any HTTP response means the service is reachable.
		resp, err := httpClient.Get(baseURL + "/")
		if err == nil {
			defer drainAndClose(resp.Body)
			// Treat 2xx/3xx/4xx as "reachable"; 5xx likely means the app is up but unhealthy.
			if resp.StatusCode < 500 {
				fmt.Printf("✅ Success: %s is reachable (Status: %d)\n", baseURL, resp.StatusCode)
				lastErr = nil
				break
			}
			lastErr = fmt.Errorf("status code %d", resp.StatusCode)
		} else {
			lastErr = err
		}

		if i < maxRetries-1 {
			fmt.Printf("⏳ Attempt %d/%d failed (%v). Retrying in 2s...\n", i+1, maxRetries, lastErr)
			time.Sleep(2 * time.Second)
		}
	}

	if lastErr != nil {
		t.Fatalf("❌ Failed to reach system after %d attempts. Last error: %v", maxRetries, lastErr)
	}

	// Run comprehensive integration tests as subtests
	t.Run("DatabaseConnectivity", databaseConnectivity)
	t.Run("RedisConnectivity", redisConnectivity)
	t.Run("WebSocketConnectivity", webSocketConnectivity)
	t.Run("AuthenticationFlow", authenticationFlow)
	t.Run("AgentManagerIntegration", agentManagerIntegration)
	t.Run("ExternalServiceConnectivity", externalServiceConnectivity)

	if t.Failed() {
		fmt.Println("❌ Some smoke tests failed.")
	} else {
		fmt.Println("🎉 All smoke tests completed!")
	}
}

func databaseConnectivity(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping database connectivity test")
	}

	// Test readiness endpoint which includes database status
	resp, err := httpClient.Get(baseURL + "/api/v2/system/ready")
	if err != nil {
		t.Fatalf("❌ Health endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 && resp.StatusCode != 503 {
		t.Errorf("❌ Readiness check failed: status %d", resp.StatusCode)
		return
	}

	// Parse response to verify database status
	var ready map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&ready); err != nil {
		t.Errorf("❌ Failed to parse readiness response: %v", err)
		return
	}

	data, ok := ready["data"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ Readiness response missing data")
		return
	}

	components, ok := data["components"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ Readiness response missing components")
		return
	}

	if dbStatus, ok := components["database"].(string); ok && dbStatus == "ok" {
		t.Log("✅ Database connectivity verified (readiness database=ok)")
	} else {
		t.Errorf("❌ Database connectivity not confirmed (database=%v)", components["database"])
	}
}

func redisConnectivity(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping Redis connectivity test")
	}

	// Test readiness endpoint which includes Redis status
	resp, err := httpClient.Get(baseURL + "/api/v2/system/ready")
	if err != nil {
		t.Fatalf("❌ Health endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 && resp.StatusCode != 503 {
		t.Errorf("❌ Readiness check returned status %d", resp.StatusCode)
		return
	}

	// Parse response to verify Redis connectivity
	var ready map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&ready); err != nil {
		t.Errorf("❌ Failed to parse readiness response: %v", err)
		return
	}

	data, ok := ready["data"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ Readiness response missing data")
		return
	}

	components, ok := data["components"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ Readiness response missing components")
		return
	}

	if redisStatus, ok := components["redis"].(string); ok && redisStatus == "ok" {
		t.Log("✅ Redis connectivity verified")
	} else {
		t.Errorf("❌ Redis connectivity not confirmed (redis=%v)", components["redis"])
	}
}

func webSocketConnectivity(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping WebSocket connectivity test")
	}

	wsBaseURL := os.Getenv("WS_BASE_URL")
	if wsBaseURL == "" {
		wsBaseURL = baseURL
	}

	// NOTE: `/api/v2/system/ws/ready` is an HTTP endpoint (not a websocket upgrade route).
	// Validate the websocket service by calling its readiness endpoint over HTTP.
	resp, err := httpClient.Get(wsBaseURL + "/api/v2/system/ws/ready")
	if err != nil {
		t.Fatalf("❌ WebSocket health endpoint not reachable: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		t.Errorf("❌ WebSocket health check failed: status %d", resp.StatusCode)
		return
	}

	var payload map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Errorf("❌ Failed to parse websocket health response: %v", err)
		return
	}

	data, ok := payload["data"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ WebSocket health response missing data")
		return
	}

	if data["status"] != "healthy" {
		t.Errorf("❌ WebSocket service not healthy: status=%v", data["status"])
		return
	}

	t.Log("✅ WebSocket service health verified")
}

func authenticationFlow(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping auth flow test")
	}

	email := os.Getenv("E2E_ADMIN_EMAIL")
	password := os.Getenv("E2E_ADMIN_PASSWORD")
	if email == "" {
		email = "admin@ci.example.com"
	}
	if password == "" {
		password = "ci-admin-password"
	}

	// Test login with configured admin credentials
	loginPayload := map[string]string{
		"email":    email,
		"password": password,
	}

	jsonData, _ := json.Marshal(loginPayload)
	loginURL := baseURL + "/api/v2/auth/signin"
	resp, err := httpClient.Post(loginURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		t.Fatalf("❌ Auth login endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		t.Errorf("❌ Auth login failed: status %d body=%s", resp.StatusCode, string(body))
		return
	}

	// Parse response to get JWT token
	var response map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Errorf("❌ Failed to parse auth response: %v", err)
		return
	}

	// Response shape is BaseApiResponse: data.tokens.access_token
	var token string
	if data, ok := response["data"].(map[string]interface{}); ok {
		if tokens, ok := data["tokens"].(map[string]interface{}); ok {
			if at, ok := tokens["access_token"].(string); ok {
				token = at
			}
		}
	}
	if token == "" {
		t.Errorf("❌ No access token in auth response")
		return
	}

	// Test protected endpoint with JWT
	req, _ := http.NewRequest("GET", baseURL+"/api/v2/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err = httpClient.Do(req)
	if err != nil {
		t.Errorf("❌ Protected endpoint test failed: %v", err)
		return
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode == 200 {
		t.Log("✅ Authentication flow verified")
	} else {
		body, _ := io.ReadAll(resp.Body)
		t.Errorf("❌ Protected endpoint returned status %d body=%s", resp.StatusCode, string(body))
	}
}

func agentManagerIntegration(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping agent manager test")
	}

	// Test agent health endpoint
	resp, err := httpClient.Get(baseURL + "/api/v1/health/agents")
	if err != nil {
		t.Fatalf("❌ Agent health endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		t.Errorf("❌ Agent health check failed: status %d", resp.StatusCode)
		return
	}

	// Parse response to verify agents are available
	var agentHealth map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&agentHealth); err != nil {
		t.Errorf("❌ Failed to parse agent health response: %v", err)
		return
	}

	if metrics, ok := agentHealth["metrics"].(map[string]interface{}); ok {
		if totalAgents, ok := metrics["total_agents"].(float64); ok && totalAgents > 0 {
			t.Logf("✅ Agent manager integration verified (%d agents available)", int(totalAgents))
		} else {
			t.Log("⚠️  No agents available in agent health response")
		}
	} else {
		t.Log("✅ Agent manager endpoint accessible (metrics missing)")
	}
}

func externalServiceConnectivity(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping external service test")
	}

	// Check diagnostics for external service indicators
	resp, err := httpClient.Get(baseURL + "/api/v2/system/diagnostics")
	if err != nil {
		t.Fatalf("❌ Diagnostics endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 && resp.StatusCode != 503 {
		t.Errorf("❌ Diagnostics check failed: status %d", resp.StatusCode)
		return
	}

	// Parse diagnostics response for external service indicators
	var diagnostics map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&diagnostics); err != nil {
		t.Errorf("❌ Failed to parse diagnostics response: %v", err)
		return
	}

	data, ok := diagnostics["data"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ Diagnostics response missing data")
		return
	}

	dependencies, ok := data["dependencies"].(map[string]interface{})
	if !ok {
		t.Errorf("❌ Diagnostics response missing dependencies")
		return
	}

	// Hard failures for core infra.
	if db, ok := dependencies["database"].(map[string]interface{}); ok {
		if status, ok := db["status"].(string); ok && status != "ok" {
			t.Errorf("❌ Diagnostics reports database status=%s", status)
			return
		}
	} else {
		t.Errorf("❌ Diagnostics missing database dependency status")
		return
	}

	if redis, ok := dependencies["redis"].(map[string]interface{}); ok {
		if status, ok := redis["status"].(string); ok && status != "ok" {
			t.Errorf("❌ Diagnostics reports redis status=%s", status)
			return
		}
	} else {
		t.Errorf("❌ Diagnostics missing redis dependency status")
		return
	}

	// Warnings for external deps when degraded.
	if aws, ok := dependencies["aws_sts"].(map[string]interface{}); ok {
		if status, ok := aws["status"].(string); ok && status != "ok" {
			t.Logf("⚠️  AWS STS status: %s", status)
		} else {
			t.Logf("ℹ️  AWS STS status: %v", aws["status"])
		}
	}
	if anthropic, ok := dependencies["anthropic_api"].(map[string]interface{}); ok {
		if status, ok := anthropic["status"].(string); ok && status != "ok" {
			t.Logf("⚠️  Anthropic API status: %s", status)
		} else {
			t.Logf("ℹ️  Anthropic API status: %v", anthropic["status"])
		}
	}

	t.Log("✅ External service connectivity assessment completed")
}
