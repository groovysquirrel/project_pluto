/**
 * Project Pluto - Portal Application
 * Enhanced with reliable authentication and service status checks
 */

const CONFIG = {
    cognito: {
        loginUrl: window.ENV_COGNITO_LOGIN_URL || "",
        clientId: window.ENV_COGNITO_CLIENT_ID || "",
        domain: window.ENV_COGNITO_DOMAIN || "",
        logoutRedirectUri: window.ENV_LOGOUT_REDIRECT_URI || window.location.origin
    },
    apps: {
        openwebui: {
            id: 'openwebui',
            name: 'OpenWebUI',
            url: window.ENV_APP_OPENWEBUI || 'https://openwebui.pluto.patternsatscale.com',
            healthUrl: '/health'
        },
        litellm: {
            id: 'litellm',
            name: 'LiteLLM Proxy',
            url: window.ENV_APP_LITELLM || 'https://litellm.pluto.patternsatscale.com/ui',
            healthUrl: '/health'
        },
        n8n: {
            id: 'n8n',
            name: 'n8n Workflows',
            url: window.ENV_APP_N8N || 'https://n8n.pluto.patternsatscale.com',
            healthUrl: '/'
        }
    },
    // Session check interval (30 seconds)
    sessionCheckInterval: 30000,
    // Service health check interval (60 seconds)
    healthCheckInterval: 60000
};

let user = null;
let sessionCheckTimer = null;
let healthCheckTimer = null;
let isCheckingSession = false;

/**
 * Initialize the application
 */
async function init() {
    console.log('[Pluto] Initializing portal...');

    // Handle OAuth callback if present
    handleAuthCallback();

    // Check authentication status
    await checkOAuth2ProxySession();

    // Render UI
    render();

    // Start periodic session checks
    startSessionMonitoring();

    // Start service health checks (if authenticated)
    if (user) {
        startHealthChecks();
    }

    console.log('[Pluto] Portal initialized');
}

/**
 * Start periodic session validation
 * Checks every 30 seconds to ensure session is still valid
 */
function startSessionMonitoring() {
    // Clear any existing timer
    if (sessionCheckTimer) {
        clearInterval(sessionCheckTimer);
    }

    // Check session periodically
    sessionCheckTimer = setInterval(async () => {
        console.log('[Pluto Auth] Periodic session check...');
        const wasAuthenticated = !!user;
        await checkOAuth2ProxySession();
        const isAuthenticated = !!user;

        // If auth state changed, update UI
        if (wasAuthenticated !== isAuthenticated) {
            console.log('[Pluto Auth] Session state changed, updating UI');
            render();

            // Start/stop health checks based on auth state
            if (isAuthenticated) {
                startHealthChecks();
            } else {
                stopHealthChecks();
            }
        }
    }, CONFIG.sessionCheckInterval);
}

/**
 * Check if user is authenticated via oauth2-proxy
 * This is the source of truth for authentication state
 */
async function checkOAuth2ProxySession() {
    // Prevent concurrent checks
    if (isCheckingSession) {
        console.log('[Pluto Auth] Session check already in progress, skipping');
        return;
    }

    isCheckingSession = true;

    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 5000); // 5 second timeout

        const response = await fetch('/oauth2/userinfo', {
            credentials: 'include',
            signal: controller.signal,
            cache: 'no-cache'
        });

        clearTimeout(timeoutId);

        if (response.ok) {
            const userInfo = await response.json();

            if (userInfo.email) {
                const displayName = extractDisplayName(userInfo);

                // Update user object
                user = {
                    email: userInfo.email,
                    sub: userInfo.sub || userInfo.user || userInfo.email,
                    name: displayName,
                    lastCheck: Date.now()
                };

                // Cache in localStorage
                localStorage.setItem('pluto_user', JSON.stringify(user));
                console.log('[Pluto Auth] ✓ Authenticated as:', user.email);
                return true;
            }
        }

        // Not authenticated or invalid response
        console.log('[Pluto Auth] ✗ Not authenticated (status:', response.status + ')');
        clearSession();
        return false;

    } catch (error) {
        if (error.name === 'AbortError') {
            console.error('[Pluto Auth] Session check timed out');
        } else {
            console.error('[Pluto Auth] Session check failed:', error.message);
        }

        // On network error, check if we have a recent cached session
        const cached = checkCachedSession();
        if (!cached) {
            clearSession();
        }
        return cached;

    } finally {
        isCheckingSession = false;
    }
}

/**
 * Check if we have a valid cached session (less than 5 minutes old)
 */
function checkCachedSession() {
    try {
        const storedUser = localStorage.getItem('pluto_user');
        if (storedUser) {
            const cachedUser = JSON.parse(storedUser);
            const age = Date.now() - (cachedUser.lastCheck || 0);

            // Use cache if less than 5 minutes old
            if (age < 300000) {
                user = cachedUser;
                console.log('[Pluto Auth] Using cached session (age:', Math.round(age / 1000), 's)');
                return true;
            }
        }
    } catch (e) {
        console.error('[Pluto Auth] Failed to read cached session:', e);
    }
    return false;
}

/**
 * Clear session data
 */
function clearSession() {
    user = null;
    localStorage.removeItem('pluto_user');
    localStorage.removeItem('pluto_id_token');
}

/**
 * Extract display name from various possible Cognito/oauth2-proxy fields
 */
function extractDisplayName(userInfo) {
    if (userInfo.name && userInfo.name !== userInfo.email) return userInfo.name;
    if (userInfo.given_name || userInfo.family_name) {
        return [userInfo.given_name, userInfo.family_name].filter(Boolean).join(' ');
    }
    if (userInfo.preferred_username) return userInfo.preferred_username;
    if (userInfo.preferredUsername) return userInfo.preferredUsername;
    if (userInfo['cognito:username']) return userInfo['cognito:username'];
    return userInfo.email?.split('@')[0] || 'User';
}

/**
 * Handle Auth Callback from Cognito (Legacy - oauth2-proxy handles this now)
 */
function handleAuthCallback() {
    const hash = window.location.hash;

    if (hash && hash.includes('id_token=')) {
        console.log('[Pluto Auth] OAuth callback detected');
        const params = new URLSearchParams(hash.substring(1));
        const idToken = params.get('id_token');

        if (idToken) {
            try {
                const payload = JSON.parse(atob(idToken.split('.')[1]));
                localStorage.setItem('pluto_id_token', idToken);
                console.log('[Pluto Auth] Token cached');

                // Clean URL
                history.replaceState(null, null, window.location.pathname);
            } catch (e) {
                console.error('[Pluto Auth] Failed to parse token:', e);
            }
        }
    }
}

/**
 * Handle auth button click
 */
function handleAuth() {
    if (user) {
        logout();
    } else {
        login();
    }
}

/**
 * Trigger Login Flow
 */
function login() {
    console.log('[Pluto Auth] Initiating login...');

    // Show loading state
    const authButton = document.getElementById('authButton');
    if (authButton) {
        authButton.disabled = true;
        authButton.textContent = 'Signing in...';
    }

    // Redirect to oauth2-proxy start flow (which redirects to Cognito)
    window.location.href = '/oauth2/start?rd=' + encodeURIComponent(window.location.pathname);
}

/**
 * Logout and clear session
 */
function logout() {
    console.log('[Pluto Auth] Initiating logout...');

    // Show loading state
    const authButton = document.getElementById('authButton');
    if (authButton) {
        authButton.disabled = true;
        authButton.textContent = 'Signing out...';
    }

    // Clear local session immediately
    clearSession();

    // Stop health checks
    stopHealthChecks();

    // Build logout URL
    const cognitoDomain = CONFIG.cognito.domain;
    const clientId = CONFIG.cognito.clientId;
    const logoutUri = encodeURIComponent(CONFIG.cognito.logoutRedirectUri);

    if (cognitoDomain && !cognitoDomain.includes('{{')) {
        // Full logout: oauth2-proxy → Cognito → back to portal
        const cognitoLogoutUrl = `https://${cognitoDomain}/logout?client_id=${clientId}&logout_uri=${logoutUri}`;
        window.location.href = `/oauth2/sign_out?rd=${encodeURIComponent(cognitoLogoutUrl)}`;
    } else {
        // Just clear oauth2-proxy session
        window.location.href = '/oauth2/sign_out';
    }
}

/**
 * Render UI based on auth state
 */
function render() {
    const authButton = document.getElementById('authButton');
    const authStatus = document.getElementById('authStatus');
    const heroAction = document.getElementById('heroAction');
    const launchButtons = document.querySelectorAll('.btn-launch');

    if (user) {
        // Authenticated state
        if (authButton) {
            authButton.textContent = 'Sign Out';
            authButton.disabled = false;
            authButton.classList.remove('btn-primary');
            authButton.classList.add('btn-secondary');
        }

        if (authStatus) {
            authStatus.innerHTML = `
                <span class="auth-indicator">●</span>
                <span class="user-name">${escapeHtml(user.name)}</span>
            `;
        }

        if (heroAction) {
            heroAction.textContent = 'Select a tool below to get started.';
        }

        // Enable launch buttons
        launchButtons.forEach(btn => {
            btn.disabled = false;
            const textEl = btn.querySelector('.launch-text');
            if (textEl) textEl.textContent = 'Launch →';
        });

        // Add authenticated class to tool cards
        document.querySelectorAll('.tool-card').forEach(card => {
            card.classList.add('authenticated');
        });

    } else {
        // Not authenticated
        if (authButton) {
            authButton.textContent = 'Sign In';
            authButton.disabled = false;
            authButton.classList.add('btn-primary');
            authButton.classList.remove('btn-secondary');
        }

        if (authStatus) {
            authStatus.innerHTML = '';
        }

        if (heroAction) {
            heroAction.textContent = 'Sign in to get started.';
        }

        // Disable launch buttons
        launchButtons.forEach(btn => {
            btn.disabled = true;
            const textEl = btn.querySelector('.launch-text');
            if (textEl) textEl.textContent = 'Sign in to launch';
        });

        // Remove authenticated class
        document.querySelectorAll('.tool-card').forEach(card => {
            card.classList.remove('authenticated');
        });
    }
}

/**
 * Launch an application
 */
function launchApp(appId) {
    if (!user) {
        login();
        return;
    }

    const app = CONFIG.apps[appId];
    if (!app) {
        console.error('[Pluto] Unknown app:', appId);
        return;
    }

    console.log('[Pluto] Launching:', app.name);
    window.open(app.url, '_blank');
}

/**
 * Start service health checks
 */
function startHealthChecks() {
    if (!user) return;

    // Initial check
    checkServiceHealth();

    // Clear any existing timer
    if (healthCheckTimer) {
        clearInterval(healthCheckTimer);
    }

    // Periodic checks
    healthCheckTimer = setInterval(checkServiceHealth, CONFIG.healthCheckInterval);
}

/**
 * Stop service health checks
 */
function stopHealthChecks() {
    if (healthCheckTimer) {
        clearInterval(healthCheckTimer);
        healthCheckTimer = null;
    }

    // Clear all status indicators
    Object.keys(CONFIG.apps).forEach(appId => {
        updateServiceStatus(appId, 'unknown');
    });
}

/**
 * Check health of all services
 */
async function checkServiceHealth() {
    if (!user) return;

    console.log('[Pluto Health] Checking service status...');

    for (const [appId, app] of Object.entries(CONFIG.apps)) {
        checkSingleService(appId, app);
    }
}

/**
 * Check health of a single service
 */
async function checkSingleService(appId, app) {
    try {
        const healthUrl = app.url.replace(/\/ui$/, '') + app.healthUrl;

        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 5000);

        const response = await fetch(healthUrl, {
            method: 'HEAD',
            mode: 'no-cors', // Avoid CORS issues
            signal: controller.signal,
            cache: 'no-cache'
        });

        clearTimeout(timeoutId);

        // With no-cors, we can't read the response, but if it doesn't error, service is up
        updateServiceStatus(appId, 'healthy');

    } catch (error) {
        // Service is down or unreachable
        updateServiceStatus(appId, 'unhealthy');
    }
}

/**
 * Update service status indicator
 */
function updateServiceStatus(appId, status) {
    const card = document.querySelector(`[data-tool="${appId}"]`);
    if (!card) return;

    // Remove existing status classes
    card.classList.remove('status-healthy', 'status-unhealthy', 'status-unknown');

    // Add new status class
    card.classList.add(`status-${status}`);

    // Update or create status indicator
    let indicator = card.querySelector('.service-status');
    if (!indicator) {
        indicator = document.createElement('div');
        indicator.className = 'service-status';
        card.querySelector('.tool-header').appendChild(indicator);
    }

    indicator.setAttribute('data-status', status);
    indicator.setAttribute('title',
        status === 'healthy' ? 'Service is running' :
        status === 'unhealthy' ? 'Service is down' :
        'Status unknown'
    );
}

/**
 * Escape HTML to prevent XSS
 */
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Global exports for onclick handlers
window.handleAuth = handleAuth;
window.login = login;
window.logout = logout;
window.launchApp = launchApp;

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
    if (sessionCheckTimer) clearInterval(sessionCheckTimer);
    if (healthCheckTimer) clearInterval(healthCheckTimer);
});

// Boot
document.addEventListener('DOMContentLoaded', init);
