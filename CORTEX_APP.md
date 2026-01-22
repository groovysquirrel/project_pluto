To set up the **OpenWebUI Cortex** app (or any compatible native client like the planned desktop/mobile companions) to find your server behind an **Application Load Balancer (ALB)**, you typically need to expose specific API and discovery endpoints.

Since most "Cortex" style apps (including third-party clients like **Cortex** by *cortex.so* or similar local LLM runners) connect via **OpenAI-compatible APIs**, you must ensure your ALB routes traffic to the correct OpenWebUI paths.

### **1. Required Discovery & API URLs**

To allow the app to "discover" and connect to your instance, ensure the following paths are accessible through your Load Balancer:

* **Base URL (Server Address):**
* `https://your-domain.com/`
* *Note:* The app usually just needs this root URL. It will append the necessary API paths automatically.


* **OpenAI-Compatible API Endpoint:**
* `https://your-domain.com/api/v1`
* *Why:* OpenWebUI exposes an OpenAI-compatible API at this path. Most third-party apps (like Cortex) use this to fetch models (`/v1/models`) and send chat completions (`/v1/chat/completions`).


* **Ollama Proxy Endpoint (Optional but Recommended):**
* `https://your-domain.com/ollama`
* *Why:* If the app expects a raw Ollama connection, OpenWebUI proxies this at `/ollama`.


* **Manifest & Configuration (For Auto-Discovery/PWA):**
* `https://your-domain.com/manifest.json`
* `https://your-domain.com/api/config`
* `https://your-domain.com/health` (Useful for the ALB health check).



### **2. Load Balancer Configuration (Crucial)**

Since OpenWebUI uses real-time streaming and stateful connections, a standard HTTP load balancer setup often fails without these specific settings:

* **WebSockets Support:**
* You **MUST** enable WebSocket support on your ALB. OpenWebUI uses `socket.io` for real-time chat generation.
* Ensure the path `/ws/` or `/socket.io/` is routed correctly and allows connection upgrades (HTTP 1.1 `Upgrade: websocket`).


* **Sticky Sessions (Session Persistence):**
* **Enable Sticky Sessions** (Cookie-based).
* *Why:* OpenWebUI stores session data. If your ALB balances requests between multiple OpenWebUI replicas (pods/containers) without sticky sessions, the app will lose context or fail to stream responses.


* **CORS Configuration (On Server):**
* If the Cortex app runs locally (e.g., `localhost`) but connects to your remote domain, you must set the `CORS_ALLOW_ORIGIN` environment variable in your OpenWebUI container:
```bash
CORS_ALLOW_ORIGIN="https://your-domain.com,app://cortex,http://localhost:*"

```





### **3. Connection Check**

When entering the server address in the app:

1. **Host:** Enter your full HTTPS domain (e.g., `https://chat.mycompany.com`).
2. **API Key:** Generate an API key from OpenWebUI (**Settings > Account > API Keys**) and use it in the app.

Would you like me to generate a specific Nginx or AWS ALB configuration snippet for these paths?

[Setup OpenWebUI Server](https://www.youtube.com/watch?v=BujhcK1KHhs)
This video is relevant as it walks through the complete server setup for OpenWebUI, including networking considerations that apply when placing it behind a load balancer.