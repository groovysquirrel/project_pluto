"""
User Provisioning Worker Lambda
Processes SQS messages to invite users to n8n.

NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers (X-Forwarded-Email).
This Lambda is ONLY responsible for n8n user invitations, which cannot use trusted headers.

This Lambda is triggered by SQS messages from the user provisioning queue.
If processing fails, the message returns to the queue for retry (up to 5 times).
After max retries, failed messages move to the dead letter queue for manual review.
"""

import json
import os
import urllib.request
import urllib.error
import boto3
from botocore.exceptions import ClientError


def get_secret(secret_name: str) -> str:
    """Retrieve secret value from AWS Secrets Manager."""
    client = boto3.client("secretsmanager")
    try:
        response = client.get_secret_value(SecretId=secret_name)
        return response["SecretString"]
    except ClientError as e:
        print(f"Error retrieving secret {secret_name}: {e}")
        raise


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
    import traceback

    print(f"📥 Received {len(event.get('Records', []))} message(s)")
    print(f"Event: {json.dumps(event)}")

    # Get configuration from environment
    n8n_url = os.environ.get("N8N_URL")
    n8n_api_key_secret = os.environ.get("N8N_API_KEY_SECRET")

    # Validate configuration
    if not n8n_url or not n8n_api_key_secret:
        print("❌ CRITICAL: N8N_URL or N8N_API_KEY_SECRET not configured")
        print(f"N8N_URL: {n8n_url or '(not set)'}")
        print(f"N8N_API_KEY_SECRET: {n8n_api_key_secret or '(not set)'}")
        # Don't raise - would send all messages to DLQ. Better to log and skip.
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "N8N configuration missing"})
        }

    # Process each SQS message
    processed_count = 0
    failed_count = 0

    for record in event.get("Records", []):
        receipt_handle = record.get("receiptHandle", "unknown")
        message_id = record.get("messageId", "unknown")

        try:
            print(f"\n{'='*80}")
            print(f"📨 Processing message {message_id}")
            print(f"Receipt Handle: {receipt_handle[:20]}...")

            # Parse message body
            try:
                message = json.loads(record["body"])
            except json.JSONDecodeError as e:
                print(f"❌ Invalid JSON in message body: {e}")
                print(f"Raw body: {record.get('body', '')}")
                # Don't raise - malformed message should go to DLQ
                failed_count += 1
                continue

            email = message.get("email")
            name = message.get("name", "")

            if not email:
                print(f"❌ No email in message: {message}")
                print(f"Message will be retried {5 - int(record.get('attributes', {}).get('ApproximateReceiveCount', 0))} more times")
                # Don't raise - invalid message format should go to DLQ eventually
                failed_count += 1
                continue

            print(f"👤 User: {email}")
            print(f"📝 Name: {name or '(empty)'}")
            print(f"🔄 Receive Count: {record.get('attributes', {}).get('ApproximateReceiveCount', 'unknown')}")

            # NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers
            # This Lambda only handles n8n invitations

            # Invite user to n8n
            try:
                print(f"\n📧 Inviting {email} to n8n...")
                print(f"🌐 n8n URL: {n8n_url}")

                # Get n8n API key from Secrets Manager
                try:
                    print(f"🔐 Retrieving n8n API key from Secrets Manager...")
                    api_key = get_secret(n8n_api_key_secret)
                    print(f"✅ Successfully retrieved API key")
                except ClientError as e:
                    error_code = e.response.get('Error', {}).get('Code', 'Unknown')
                    print(f"❌ Secrets Manager error ({error_code}): {e}")
                    print(f"Traceback:\n{traceback.format_exc()}")
                    # Raise to retry - secrets might be temporarily unavailable
                    raise Exception(f"Failed to retrieve n8n API key: {error_code}")
                except Exception as e:
                    print(f"❌ Unexpected error retrieving n8n API key: {e}")
                    print(f"Traceback:\n{traceback.format_exc()}")
                    raise

                # Invite user to n8n
                result = invite_user_to_n8n(email, api_key, n8n_url)

                if result.get("status") in [200, 201]:
                    print(f"✅ Successfully invited {email} to n8n")
                    print(f"Response: {json.dumps(result.get('body', {}), indent=2)}")
                elif result.get("status") == 409:
                    # 409 Conflict - user already invited (idempotent success)
                    print(f"⚠️  User {email} already invited to n8n (409 Conflict - this is fine)")
                    print(f"Response: {result.get('error', '')}")
                elif result.get("status") == 404:
                    # 404 - endpoint might not exist or n8n version doesn't support this API
                    print(f"❌ n8n invitation endpoint not found (404)")
                    print(f"Response: {result.get('error', '')}")
                    print(f"This typically means n8n doesn't support the /api/v1/invitations endpoint")
                    print(f"ACTION REQUIRED: Verify n8n API endpoint and version")
                    # Raise to trigger retry, will eventually go to DLQ for manual review
                    raise Exception(f"n8n API endpoint not found: {result.get('error', '')}")
                elif result.get("status") == 0:
                    # Network error (URLError)
                    print(f"❌ Network error connecting to n8n: {result.get('error', '')}")
                    print(f"This is typically a timeout or connection refused error")
                    # Raise to trigger retry - service might be temporarily down
                    raise Exception(f"Network error: {result.get('error', '')}")
                elif result.get("status") >= 500:
                    # Server error - should retry
                    print(f"❌ n8n server error ({result.get('status')}): {result.get('error', '')}")
                    # Raise to trigger retry - server might be temporarily unavailable
                    raise Exception(f"Server error {result.get('status')}: {result.get('error', '')}")
                elif result.get("status") == 401 or result.get("status") == 403:
                    # Authentication/Authorization error
                    print(f"❌ n8n authentication error ({result.get('status')}): {result.get('error', '')}")
                    print(f"ACTION REQUIRED: Verify N8N_API_KEY in Secrets Manager is correct")
                    # Raise to trigger retry, will eventually go to DLQ
                    raise Exception(f"Authentication error {result.get('status')}: {result.get('error', '')}")
                else:
                    # Other client error (4xx)
                    print(f"❌ Failed to invite {email} to n8n: {result}")
                    print(f"Status: {result.get('status')}")
                    print(f"Error: {result.get('error', '')}")
                    # Raise to trigger retry, will eventually go to DLQ
                    raise Exception(f"n8n invitation failed (status {result.get('status')}): {result.get('error', '')}")

            except Exception as e:
                print(f"❌ Error inviting user to n8n: {e}")
                print(f"Traceback:\n{traceback.format_exc()}")
                failed_count += 1
                raise  # Re-raise to trigger SQS retry

            print(f"\n✅ Successfully processed message {message_id} for {email}")
            processed_count += 1

        except Exception as e:
            print(f"\n❌ FATAL: Error processing message {message_id}: {e}")
            print(f"Traceback:\n{traceback.format_exc()}")
            print(f"Message will be retried. After 5 total attempts, it will move to DLQ.")
            failed_count += 1
            # Re-raise to trigger SQS retry (message stays in queue)
            raise

    print(f"\n{'='*80}")
    print(f"📊 Summary: Processed {processed_count}, Failed {failed_count}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Processing complete",
            "processed": processed_count,
            "failed": failed_count
        })
    }
