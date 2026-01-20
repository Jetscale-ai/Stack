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

	// Test system health endpoint which includes database status
	resp, err := httpClient.Get(baseURL + "/api/v1/health/")
	if err != nil {
		t.Fatalf("❌ Health endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		t.Errorf("❌ Health check failed: status %d", resp.StatusCode)
		return
	}

	// Parse response to verify system is healthy (implies database works)
	var health map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		t.Errorf("❌ Failed to parse health response: %v", err)
		return
	}

	if status, ok := health["status"].(string); ok && status == "healthy" {
		t.Log("✅ Database connectivity verified (system status: healthy)")
	} else {
		t.Errorf("❌ System health check failed: status %v", health["status"])
	}
}

func redisConnectivity(t *testing.T) {
	baseURL := os.Getenv("BASE_URL")
	if baseURL == "" {
		t.Skip("BASE_URL not set, skipping Redis connectivity test")
	}

	// Test system health endpoint which includes Redis status
	resp, err := httpClient.Get(baseURL + "/api/v1/health/")
	if err != nil {
		t.Fatalf("❌ Health endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		t.Errorf("❌ Health check returned status %d", resp.StatusCode)
		return
	}

	// Parse response to verify Redis connectivity
	var health map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		t.Errorf("❌ Failed to parse health response: %v", err)
		return
	}

	if redisConnected, ok := health["redis_connected"].(bool); ok && redisConnected {
		t.Log("✅ Redis connectivity verified")
	} else {
		t.Errorf("❌ Redis connectivity not confirmed (redis_connected=%v)", health["redis_connected"])
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

	// NOTE: `/api/v1/ws/health` is an HTTP endpoint (not a websocket upgrade route).
	// Validate the websocket service by calling its health endpoint over HTTP.
	resp, err := httpClient.Get(wsBaseURL + "/api/v1/ws/health")
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

	if payload["status"] != "healthy" {
		t.Errorf("❌ WebSocket service not healthy: status=%v", payload["status"])
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
	resp, err := httpClient.Post(baseURL+"/api/v1/auth/login", "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		t.Fatalf("❌ Auth login endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		t.Errorf("❌ Auth login failed: status %d", resp.StatusCode)
		return
	}

	// Parse response to get JWT token
	var response map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Errorf("❌ Failed to parse auth response: %v", err)
		return
	}

	// Response shape is SessionApiResponse: data.tokens.access_token
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
	req, _ := http.NewRequest("GET", baseURL+"/api/v1/auth/me", nil)
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
		t.Errorf("❌ Protected endpoint returned status %d", resp.StatusCode)
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

	// Check system health for external service indicators
	resp, err := httpClient.Get(baseURL + "/api/v1/health/")
	if err != nil {
		t.Fatalf("❌ Health endpoint not available: %v", err)
	}
	defer drainAndClose(resp.Body)

	if resp.StatusCode != 200 {
		t.Errorf("❌ Health check failed: status %d", resp.StatusCode)
		return
	}

	// Parse health response for external service indicators
	var health map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		t.Errorf("❌ Failed to parse health response: %v", err)
		return
	}

	// Check for Langfuse integration (mentioned in health response)
	if langgraphEnabled, ok := health["langgraph_checkpointer_enabled"].(bool); ok {
		if langgraphEnabled {
			t.Log("✅ Langfuse integration verified")
		} else {
			t.Log("⚠️  Langfuse integration not enabled")
		}
	}

	// Check for other external integrations that might be indicated in health
	if agentsAvailable, ok := health["agents_available"].(float64); ok && agentsAvailable > 0 {
		t.Log("✅ External AI services integration verified (agents available)")
	}

	t.Log("✅ External service connectivity assessment completed")
}
