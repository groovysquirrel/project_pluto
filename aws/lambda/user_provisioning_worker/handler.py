"""
User Provisioning Worker Lambda
Processes SQS messages to create users in OpenWebUI and invite to n8n.

This Lambda is triggered by SQS messages from the user provisioning queue.
If processing fails, the message returns to the queue for retry (up to 5 times).
After max retries, failed messages move to the dead letter queue for manual review.
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
    Create a user in OpenWebUI using the SCIM 2.0 API.

    SCIM (System for Cross-domain Identity Management) is the standard API
    for user provisioning in OpenWebUI.

    Args:
        email: User's email address
        name: User's display name
        openwebui_url: Base URL of OpenWebUI instance
        api_key: OpenWebUI API key (JWT token) for authentication

    Returns:
        API response as dict
    """
    url = f"{openwebui_url}/api/v1/scim/v2/Users"

    # Split name into first/last for SCIM format
    name_parts = (name or email.split("@")[0]).split(" ", 1)
    given_name = name_parts[0]
    family_name = name_parts[1] if len(name_parts) > 1 else ""

    # SCIM 2.0 user creation payload
    display_name = name or email.split("@")[0]
    payload = json.dumps({
        "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName": email,
        "displayName": display_name,
        "emails": [
            {
                "value": email,
                "primary": True
            }
        ],
        "name": {
            "givenName": given_name,
            "familyName": family_name
        },
        "active": True
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/scim+json"
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
    SQS event handler for user provisioning.
    Processes messages from the user provisioning queue.
    """
    print(f"Event: {json.dumps(event)}")

    # Get configuration from environment
    openwebui_url = os.environ.get("OPENWEBUI_URL")
    openwebui_api_key_secret = os.environ.get("OPENWEBUI_API_KEY_SECRET")
    n8n_url = os.environ.get("N8N_URL")
    n8n_api_key_secret = os.environ.get("N8N_API_KEY_SECRET")

    # Process each SQS message
    for record in event.get("Records", []):
        try:
            # Parse message body
            message = json.loads(record["body"])
            email = message.get("email")
            name = message.get("name", "")

            if not email:
                print(f"❌ No email in message: {message}")
                continue

            print(f"📨 Processing user: {email} ({name})")

            # Create user in OpenWebUI
            if openwebui_url:
                try:
                    # Get OpenWebUI API key from Secrets Manager
                    openwebui_api_key = None
                    if openwebui_api_key_secret:
                        try:
                            openwebui_api_key = get_secret(openwebui_api_key_secret)
                        except Exception as e:
                            print(f"⚠️  Could not retrieve OpenWebUI API key: {e}")
                            # Continue without API key - will likely fail but let's try

                    result = create_user_in_openwebui(email, name, openwebui_url, openwebui_api_key)

                    if result.get("status") in [200, 201]:
                        print(f"✅ Successfully created {email} in OpenWebUI")
                    elif result.get("status") == 400 and "already exists" in str(result.get("error", "")).lower():
                        print(f"⚠️  User {email} already exists in OpenWebUI (this is fine)")
                    else:
                        print(f"❌ Failed to create {email} in OpenWebUI: {result}")
                        # Raise to trigger SQS retry
                        raise Exception(f"OpenWebUI user creation failed: {result}")

                except Exception as e:
                    print(f"❌ Error creating user in OpenWebUI: {e}")
                    raise  # Re-raise to trigger SQS retry
            else:
                print("⚠️  OPENWEBUI_URL not configured")

            # TODO: n8n user provisioning disabled until we verify the correct API endpoint
            # The /api/v1/invitations endpoint returns 404
            # Need to investigate correct endpoint via n8n's Swagger docs
            # if n8n_url and n8n_api_key_secret:
            #     try:
            #         # Get n8n API key from Secrets Manager
            #         api_key = get_secret(n8n_api_key_secret)
            #
            #         # Invite user to n8n
            #         result = invite_user_to_n8n(email, api_key, n8n_url)
            #
            #         if result.get("status") in [200, 201]:
            #             print(f"✅ Successfully invited {email} to n8n")
            #         elif result.get("status") == 409:
            #             print(f"⚠️  User {email} already exists in n8n (this is fine)")
            #         else:
            #             print(f"⚠️  Failed to invite {email} to n8n: {result}")
            #             # Don't raise - n8n failure shouldn't block OpenWebUI user creation
            #
            #     except Exception as e:
            #         print(f"⚠️  Error inviting user to n8n: {e}")
            #         # Don't raise - n8n failure shouldn't block OpenWebUI user creation
            # else:
            #     print("⚠️  N8N_URL or N8N_API_KEY_SECRET not configured")

            print(f"✅ Successfully processed {email}")

        except Exception as e:
            print(f"❌ Error processing message: {e}")
            # Re-raise to trigger SQS retry (message stays in queue)
            raise

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Processing complete"})
    }
