"""Low-stock notifier.

Consumes LowStockDetected events delivered by EventBridge to SQS. For each one:
  1. records an ALERT item in DynamoDB (idempotent, keyed by the stream event id)
  2. emails the team through SNS
  3. marks the alert NOTIFIED
Failed messages are retried by SQS and end up in the dead-letter queue after 3 tries.
"""
import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
SNS = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]


def process(detail):
    alert_id = f"{detail['detected_at']}#{detail['stream_event_id']}"
    key = {"pk": f"PRODUCT#{detail['product_id']}", "sk": f"ALERT#{alert_id}"}
    item = {
        **key,
        "gsi1pk": "ALERT",  # lets the API list recent alerts, newest first
        "gsi1sk": alert_id,
        "name": detail.get("name"),
        "sku": detail.get("sku"),
        "stock": detail["stock"],
        "previous_stock": detail.get("previous_stock"),
        "reorder_threshold": detail["reorder_threshold"],
        "suggested_order_qty": detail.get("reorder_qty"),
        "supplier_email": detail.get("supplier_email"),
        "detected_at": detail["detected_at"],
        "status": "PENDING",
    }

    try:
        TABLE.put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        existing = TABLE.get_item(Key=key).get("Item", {})
        if existing.get("status") == "NOTIFIED":
            logger.info(json.dumps({"duplicate": alert_id}))
            return

    name = str(detail.get("name") or "Unknown product")
    SNS.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"Low stock: {name[:60]} ({detail['stock']} left)",
        Message=(
            f"Product:            {name} (SKU {detail.get('sku')})\n"
            f"Stock now:          {detail['stock']}\n"
            f"Reorder threshold:  {detail['reorder_threshold']}\n"
            f"Suggested reorder:  {detail.get('reorder_qty')} units\n"
            f"Supplier:           {detail.get('supplier_email')}\n"
            f"Detected at:        {detail['detected_at']}\n"
        ),
    )
    TABLE.update_item(
        Key=key,
        UpdateExpression="SET #s = :n, notified_at = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":n": "NOTIFIED",
            ":t": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        },
    )


def handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            body = json.loads(record["body"])
            process(body["detail"])
        except Exception:
            logger.exception("Failed to process message %s", record["messageId"])
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
