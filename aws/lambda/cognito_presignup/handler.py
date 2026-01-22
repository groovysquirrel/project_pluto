"""
Cognito Pre Sign-up Trigger Lambda

Validates that user email domains are in the allowed list.
Only users from specified domains can register via direct sign-up.
External identity providers (Google, Facebook, etc.) bypass domain validation.
"""

import os

def handler(event, context):
    """
    Pre Sign-up trigger to validate email domain.
    
    Allowed domains are configured via ALLOWED_DOMAINS environment variable
    as a comma-separated list (e.g., "patternsatscale.com,infotech.com")
    
    External identity provider signups (Google, Facebook, etc.) bypass validation.
    """
    
    trigger_source = event.get('triggerSource', '')
    
    # Skip domain validation for external identity providers (Google, Facebook, etc.)
    # These users authenticate through their IdP, so we trust their identity
    if trigger_source == 'PreSignUp_ExternalProvider':
        provider = event.get('request', {}).get('userAttributes', {}).get('identities', 'Unknown')
        email = event.get('request', {}).get('userAttributes', {}).get('email', 'Unknown')
        print(f"External IdP signup allowed for: {email} (provider: {trigger_source})")
        
        # Auto-confirm external provider users (they're already verified by their IdP)
        event['response']['autoConfirmUser'] = True
        event['response']['autoVerifyEmail'] = True
        return event
    
    # Get allowed domains from environment
    allowed_domains_str = os.environ.get('ALLOWED_DOMAINS', '')
    allowed_domains = [d.strip().lower() for d in allowed_domains_str.split(',') if d.strip()]
    
    # If no domains configured, allow all (fail-open for safety)
    if not allowed_domains:
        print("WARNING: No ALLOWED_DOMAINS configured, allowing all signups")
        return event
    
    # Get user email
    email = event.get('request', {}).get('userAttributes', {}).get('email', '')
    
    if not email:
        raise Exception("Email is required for registration")
    
    # Extract domain from email
    try:
        domain = email.split('@')[1].lower()
    except IndexError:
        raise Exception("Invalid email format")
    
    # Check if domain is allowed
    if domain not in allowed_domains:
        raise Exception(f"Registration is restricted to authorized email domains only. Domain '{domain}' is not permitted.")
    
    print(f"Signup allowed for email domain: {domain}")
    
    # Return event unchanged (Cognito continues with signup)
    return event

