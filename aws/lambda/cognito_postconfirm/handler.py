"""
Cognito Post-Confirmation Lambda
Queues n8n user invitations when users confirm their Cognito account.

ARCHITECTURE (Asynchronous with SQS):
  User Signs Up → Cognito PostConfirmation → Lambda (Producer) → SQS Queue
                                              ↓
                                        Returns immediately
                                        (user signup completes)

  SQS Queue → Worker Lambda → n8n API (invitation)
              ↑ Retries if down (5 attempts before DLQ)

NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers (X-Forwarded-Email).
This Lambda is ONLY responsible for queuing n8n invitations, not OpenWebUI user creation.

BENEFITS OF SQS APPROACH:
  - User signup completes even if n8n is temporarily unavailable
  - Automatic retries with exponential backoff (5 attempts before DLQ)
  - Dead letter queue for failed invitations (alerting/manual intervention)
  - Decouples Cognito availability from n8n availability
  - Messages retained for 4 days (won't lose invitation requests during outages)
"""

import json
import os
import boto3
from botocore.exceptions import ClientError


def handler(event, context):
    """
    Cognito Post-Confirmation trigger handler.

    This is called after a user confirms their account (email verification).
    Sends user information to SQS queue for asynchronous processing.

    CRITICAL: This Lambda must ALWAYS return the event successfully.
    If we raise an exception, Cognito will fail the user signup.
    """
    import traceback

    print(f"{'='*80}")
    print(f"🔔 Cognito Post-Confirmation Trigger")
    print(f"Event: {json.dumps(event, indent=2)}")

    # Only process confirmed signups, not forgot password confirmations
    trigger_source = event.get("triggerSource", "")
    print(f"📋 Trigger Source: {trigger_source}")

    if trigger_source not in ["PostConfirmation_ConfirmSignUp", "PostConfirmation_ConfirmForgotPassword"]:
        print(f"⏭️  Skipping unsupported trigger source: {trigger_source}")
        print(f"Supported: PostConfirmation_ConfirmSignUp, PostConfirmation_ConfirmForgotPassword")
        return event

    # For forgot password, skip invitation (user already exists)
    if trigger_source == "PostConfirmation_ConfirmForgotPassword":
        print(f"⏭️  Skipping forgot password confirmation (user already exists)")
        return event

    # Get user email and name from event
    user_attributes = event.get("request", {}).get("userAttributes", {})
    email = user_attributes.get("email")
    cognito_username = event.get("userName", "unknown")

    print(f"👤 Cognito Username: {cognito_username}")
    print(f"📧 Email: {email}")
    print(f"📝 Attributes: {json.dumps(user_attributes, indent=2)}")

    # Construct name from available attributes
    # Federated identity providers (Google, etc.) often provide given_name/family_name
    # but not a combined "name" attribute
    name = user_attributes.get("name", "")
    if not name:
        given_name = user_attributes.get("given_name", "")
        family_name = user_attributes.get("family_name", "")
        if given_name or family_name:
            name = f"{given_name} {family_name}".strip()
            print(f"📝 Constructed name from given_name + family_name: {name}")

    # If still no name, use email prefix as fallback
    if not name:
        name = email.split("@")[0] if email else ""
        print(f"📝 Using email prefix as name fallback: {name}")

    if not email:
        print("❌ WARNING: No email found in user attributes")
        print(f"User signup will succeed, but won't be invited to n8n")
        print(f"This should never happen if Cognito is configured correctly")
        return event

    print(f"\n🎯 Target: Queue {email} for n8n invitation")

    # Get SQS queue URL from environment
    queue_url = os.environ.get("USER_PROVISIONING_QUEUE_URL")

    if not queue_url:
        print("\n❌ CRITICAL: USER_PROVISIONING_QUEUE_URL not configured")
        print(f"Environment variables: {json.dumps(dict(os.environ), indent=2)}")
        print(f"User signup will succeed, but won't be invited to n8n")
        print(f"ACTION REQUIRED: Set USER_PROVISIONING_QUEUE_URL in Lambda configuration")
        # Don't fail user signup - just log the error
        return event

    print(f"📮 Queue URL: {queue_url}")

    # Send message to SQS queue
    try:
        print(f"\n📤 Sending message to SQS...")
        sqs = boto3.client("sqs")

        message_body = json.dumps({
            "email": email,
            "name": name,
            "cognitoUsername": cognito_username,
            "triggerSource": trigger_source
        })

        print(f"Message body: {message_body}")

        response = sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=message_body,
            MessageAttributes={
                "Email": {
                    "DataType": "String",
                    "StringValue": email
                },
                "TriggerSource": {
                    "DataType": "String",
                    "StringValue": trigger_source
                }
            }
        )

        message_id = response.get("MessageId", "unknown")
        print(f"\n✅ SUCCESS: Queued {email} for n8n invitation")
        print(f"📨 Message ID: {message_id}")
        print(f"📊 Response: {json.dumps(response, indent=2)}")

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        error_message = e.response.get("Error", {}).get("Message", "")
        print(f"\n❌ AWS Error sending message to queue ({error_code}): {error_message}")
        print(f"Response: {json.dumps(e.response, indent=2)}")
        print(f"Traceback:\n{traceback.format_exc()}")
        print(f"\n⚠️  User signup will succeed, but won't be invited to n8n")
        print(f"ACTION REQUIRED: Check SQS queue permissions and Lambda IAM role")
        # Don't fail user signup - the message just won't be processed

    except Exception as e:
        print(f"\n❌ Unexpected error sending message to queue: {e}")
        print(f"Traceback:\n{traceback.format_exc()}")
        print(f"\n⚠️  User signup will succeed, but won't be invited to n8n")
        print(f"ACTION REQUIRED: Investigate error in CloudWatch Logs")
        # Don't fail user signup - the message just won't be processed

    print(f"\n{'='*80}")
    print(f"🏁 Returning event to Cognito (user signup will complete)")

    # Always return the event for Cognito (user signup succeeds regardless)
    return event
