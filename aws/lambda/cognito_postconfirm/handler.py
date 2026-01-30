"""
Cognito Post-Confirmation Lambda
Automatically provisions new users in OpenWebUI and n8n when they confirm their Cognito account.

CURRENT ARCHITECTURE (Synchronous):
  Cognito PostConfirmation → Lambda → OpenWebUI API (synchronous call)
                               ↓
                          Returns to Cognito

LIMITATIONS:
  - If OpenWebUI is restarting/scaling/down during signup, user creation fails
  - No retry mechanism if API call fails
  - Blocks Cognito confirmation until API call completes

FUTURE IMPROVEMENT (Asynchronous with SQS):
  Cognito PostConfirmation → Lambda → SQS Queue → (async) → Worker → OpenWebUI API
                               ↓                                         ↑
                          Returns immediately                    Retries if down

BENEFITS OF SQS APPROACH:
  - User signup completes even if OpenWebUI is temporarily unavailable
  - Automatic retries with exponential backoff (5 attempts before DLQ)
  - Dead letter queue for failed creations (alerting/manual intervention)
  - Decouples Cognito availability from OpenWebUI availability
  - Can batch process multiple users efficiently
  - Messages retained for 4 days (won't lose signup requests)

TO IMPLEMENT SQS:
  1. Create SQS queue + DLQ in terraform/sqs.tf
  2. Update this Lambda to send message to SQS instead of direct API call
  3. Create worker Lambda to process queue and call OpenWebUI API
  4. Configure event source mapping: SQS → Worker Lambda
  5. Monitor DLQ for failed user creations (CloudWatch alarm)

For now, we validate the simple synchronous approach works first.
"""

import json
import os
import secrets
import string
import urllib.request
import urllib.error
import boto3
from botocore.exceptions import ClientError


def generate_random_password(length: int = 32) -> str:
    """Generate a random password for SSO users (they won't use it)."""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(secrets.choice(alphabet) for _ in range(length))


def get_secret(secret_name: str) -> str:
    """Retrieve secret value from AWS Secrets Manager."""
    client = boto3.client("secretsmanager")
    try:
        response = client.get_secret_value(SecretId=secret_name)
        return response["SecretString"]
    except ClientError as e:
        print(f"Error retrieving secret {secret_name}: {e}")
        raise


def create_user_in_openwebui(email: str, name: str, openwebui_url: str, api_key: str = None) -> dict:
    """
    Create a user in OpenWebUI via the signup API.

    Args:
        email: User's email address
        name: User's display name
        openwebui_url: Base URL of OpenWebUI instance
        api_key: OpenWebUI API key (JWT token) for authentication

    Returns:
        API response as dict
    """
    url = f"{openwebui_url}/api/v1/auths/signup"

    # Generate a random password - user will authenticate via SSO, not password
    password = generate_random_password()

    payload = json.dumps({
        "email": email,
        "name": name or email.split("@")[0],  # Use email prefix if no name
        "password": password
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/json"
    }

    # Add API key authentication if provided
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return {
                "status": response.status,
                "body": json.loads(response.read().decode("utf-8"))
            }
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else ""
        return {
            "status": e.code,
            "error": error_body
        }
    except urllib.error.URLError as e:
        return {
            "status": 0,
            "error": str(e.reason)
        }


def invite_user_to_n8n(email: str, api_key: str, n8n_url: str) -> dict:
    """
    Invite a user to n8n via the API.

    Args:
        email: User's email address
        api_key: n8n API key
        n8n_url: Base URL of n8n instance

    Returns:
        API response as dict
    """
    url = f"{n8n_url}/api/v1/invitations"

    payload = json.dumps({
        "email": email,
        "role": "global:member"
    }).encode("utf-8")

    headers = {
        "X-N8N-API-KEY": api_key,
        "Content-Type": "application/json"
    }

    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return {
                "status": response.status,
                "body": json.loads(response.read().decode("utf-8"))
            }
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else ""
        return {
            "status": e.code,
            "error": error_body
        }
    except urllib.error.URLError as e:
        return {
            "status": 0,
            "error": str(e.reason)
        }


def handler(event, context):
    """
    Cognito Post-Confirmation trigger handler.

    This is called after a user confirms their account (email verification).
    Sends user information to SQS queue for asynchronous processing.
    """
    print(f"Event: {json.dumps(event)}")

    # Only process confirmed signups, not forgot password confirmations
    trigger_source = event.get("triggerSource", "")
    if trigger_source not in ["PostConfirmation_ConfirmSignUp", "PostConfirmation_ConfirmForgotPassword"]:
        print(f"Skipping trigger source: {trigger_source}")
        return event

    # For forgot password, skip invitation (user already exists)
    if trigger_source == "PostConfirmation_ConfirmForgotPassword":
        print("Skipping forgot password confirmation")
        return event

    # Get user email and name from event
    user_attributes = event.get("request", {}).get("userAttributes", {})
    email = user_attributes.get("email")

    # Construct name from available attributes
    # Federated identity providers (Google, etc.) often provide given_name/family_name
    # but not a combined "name" attribute
    name = user_attributes.get("name", "")
    if not name:
        given_name = user_attributes.get("given_name", "")
        family_name = user_attributes.get("family_name", "")
        if given_name or family_name:
            name = f"{given_name} {family_name}".strip()

    # If still no name, use email prefix as fallback
    if not name:
        name = email.split("@")[0] if email else ""

    if not email:
        print("No email found in user attributes")
        return event

    print(f"📨 Queuing user for provisioning: {email} ({name})")

    # Get SQS queue URL from environment
    queue_url = os.environ.get("USER_PROVISIONING_QUEUE_URL")

    if not queue_url:
        print("❌ USER_PROVISIONING_QUEUE_URL not configured")
        # Don't fail user signup - just log the error
        return event

    # Send message to SQS queue
    try:
        sqs = boto3.client("sqs")

        message_body = json.dumps({
            "email": email,
            "name": name
        })

        response = sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=message_body
        )

        print(f"✅ Successfully queued {email} for provisioning (MessageId: {response['MessageId']})")

    except Exception as e:
        print(f"❌ Error sending message to queue: {e}")
        # Don't fail user signup - the message just won't be processed
        # We could add CloudWatch alarm on this error for monitoring

    # Always return the event for Cognito (user signup succeeds regardless)
    return event
