/**
 * Project Pluto - Portal Application
 * Handles Authentication (Cognito) and Tool Launching
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
            url: window.ENV_APP_OPENWEBUI || 'https://openwebui.pluto.patternsatscale.com'
        },
        litellm: {
            id: 'litellm',
            name: 'LiteLLM Proxy',
            url: window.ENV_APP_LITELLM || 'https://litellm.pluto.patternsatscale.com/ui'
        },
        n8n: {
            id: 'n8n',
            name: 'n8n Workflows',
            url: window.ENV_APP_N8N || 'https://n8n.pluto.patternsatscale.com'
        }
    }
};

let user = null;

/**
 * Initialize the application
 */
function init() {
    handleAuthCallback();
    checkSession();
    render();
}

/**
 * Handle Auth Callback from Cognito (Implicit Grant)
 */
function handleAuthCallback() {
    const hash = window.location.hash;

    // Debug: Log callback detection
    console.log('[Pluto Auth] Checking for auth callback...');
    console.log('[Pluto Auth] URL hash:', hash ? hash.substring(0, 100) + '...' : '(empty)');

    if (hash && hash.includes('id_token=')) {
        console.log('[Pluto Auth] ID token found in hash!');
        const params = new URLSearchParams(hash.substring(1));
        const idToken = params.get('id_token');
        const accessToken = params.get('access_token');

        console.log('[Pluto Auth] ID token extracted:', idToken ? 'yes' : 'no');
        console.log('[Pluto Auth] Access token extracted:', accessToken ? 'yes' : 'no');

        if (idToken) {
            try {
                const payload = JSON.parse(atob(idToken.split('.')[1]));
                console.log('[Pluto Auth] Token payload:', JSON.stringify(payload, null, 2));
                console.log('[Pluto Auth] Claims - email:', payload.email, 'name:', payload.name, 'sub:', payload.sub);
                console.log('[Pluto Auth] Identity provider:', payload.identities ? payload.identities[0]?.providerName : 'Cognito native');

                setSession(payload, idToken, accessToken);
                console.log('[Pluto Auth] Session set successfully!');

                // Clean URL
                history.replaceState(null, null, window.location.pathname);
            } catch (e) {
                console.error('[Pluto Auth] Failed to parse token:', e);
            }
        }
    } else if (hash && hash.length > 1) {
        // Log if there's a hash but no id_token (might help diagnose)
        console.log('[Pluto Auth] Hash present but no id_token. Contents:', hash);
    }
}

/**
 * Check for existing session
 */
function checkSession() {
    const storedUser = localStorage.getItem('pluto_user');
    if (storedUser) {
        try {
            user = JSON.parse(storedUser);
        } catch (e) {
            localStorage.removeItem('pluto_user');
        }
    }
}

/**
 * Store session data
 */
function setSession(userData, idToken, accessToken) {
    user = {
        email: userData.email,
        sub: userData.sub,
        name: userData.name || userData.email?.split('@')[0] || 'User'
    };
    localStorage.setItem('pluto_user', JSON.stringify(user));
    if (idToken) localStorage.setItem('pluto_id_token', idToken);
}

/**
 * Handle auth button click (Sign In or Sign Out)
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
    if (CONFIG.cognito.loginUrl && !CONFIG.cognito.loginUrl.includes('{{')) {
        window.location.href = CONFIG.cognito.loginUrl;
    } else {
        // Dev mode - mock login
        console.log('Dev mode: Mock login');
        const mockUser = { email: 'dev@patternsatscale.com', sub: '123', name: 'Developer' };
        setSession(mockUser, 'mock_token', 'mock_access');
        render();
    }
}

/**
 * Logout and clear session
 */
function logout() {
    localStorage.removeItem('pluto_user');
    localStorage.removeItem('pluto_id_token');
    user = null;

    const cognitoDomain = CONFIG.cognito.domain;
    const clientId = CONFIG.cognito.clientId;
    const logoutUri = encodeURIComponent(CONFIG.cognito.logoutRedirectUri);

    if (cognitoDomain && !cognitoDomain.includes('{{')) {
        const logoutUrl = `https://${cognitoDomain}/logout?client_id=${clientId}&logout_uri=${logoutUri}`;
        window.location.href = logoutUrl;
    } else {
        render();
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
        authButton.textContent = 'Sign Out';
        authButton.classList.remove('btn-primary');
        authButton.classList.add('btn-secondary');
        authStatus.innerHTML = `Welcome, <span class="user-name">${user.name}</span>`;
        heroAction.textContent = 'Select a tool below to get started.';

        // Enable launch buttons
        launchButtons.forEach(btn => {
            btn.disabled = false;
            btn.querySelector('.launch-text').textContent = 'Launch →';
        });

        // Add authenticated class to tool cards
        document.querySelectorAll('.tool-card').forEach(card => {
            card.classList.add('authenticated');
        });

    } else {
        // Public state
        authButton.textContent = 'Sign In';
        authButton.classList.add('btn-primary');
        authButton.classList.remove('btn-secondary');
        authStatus.innerHTML = '';
        heroAction.textContent = 'Sign in to get started.';

        // Disable launch buttons
        launchButtons.forEach(btn => {
            btn.disabled = true;
            btn.querySelector('.launch-text').textContent = 'Sign in to launch';
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
        console.error('Unknown app:', appId);
        return;
    }

    // Open in new tab (each app has oauth2-proxy for seamless SSO)
    window.open(app.url, '_blank');
}

// Global exports for onclick handlers
window.handleAuth = handleAuth;
window.login = login;
window.logout = logout;
window.launchApp = launchApp;

// Boot
document.addEventListener('DOMContentLoaded', init);
