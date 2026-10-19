"""Low-stock detector.

Triggered by the DynamoDB stream (only INSERT/MODIFY of product META items,
filtered at the event source mapping). Emits a LowStockDetected event to the
EventBridge bus when a product CROSSES into low stock, so selling one more unit
while already low does not send another alert.
"""
import json
import logging
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeDeserializer

logger = logging.getLogger()
logger.setLevel(logging.INFO)

EVENTS = boto3.client("events")
DESERIALIZER = TypeDeserializer()
BUS_NAME = os.environ["EVENT_BUS_NAME"]


def plain(image):
    if not image:
        return None
    return {k: DESERIALIZER.deserialize(v) for k, v in image.items()}


def is_low(item):
    if not item or "stock" not in item or "reorder_threshold" not in item:
        return False
    return int(item["stock"]) <= int(item["reorder_threshold"])


def build_entry(record, old, new):
    created = float(record["dynamodb"]["ApproximateCreationDateTime"])
    detected_at = datetime.fromtimestamp(created, timezone.utc).isoformat(timespec="seconds")
    detail = {
        "product_id": new["pk"].split("#", 1)[1],
        "name": new.get("name"),
        "sku": new.get("sku"),
        "stock": int(new["stock"]),
        "previous_stock": int(old["stock"]) if old and "stock" in old else None,
        "reorder_threshold": int(new["reorder_threshold"]),
        "reorder_qty": int(new.get("reorder_qty", 0)),
        "supplier_email": new.get("supplier_email"),
        "detected_at": detected_at,
        # Deterministic id from the stream record: lets the notifier de-duplicate retries.
        "stream_event_id": record["eventID"],
    }
    return {
        "Source": "stockwatch.inventory",
        "DetailType": "LowStockDetected",
        "Detail": json.dumps(detail),
        "EventBusName": BUS_NAME,
    }


def send(entries):
    for i in range(0, len(entries), 10):  # PutEvents accepts at most 10 entries
        resp = EVENTS.put_events(Entries=entries[i : i + 10])
        if resp["FailedEntryCount"]:
            # Raising makes Lambda retry the batch; the notifier de-duplicates.
            raise RuntimeError(f"{resp['FailedEntryCount']} event(s) failed to publish")


def handler(event, context):
    entries = []
    for record in event["Records"]:
        if record["eventName"] not in ("INSERT", "MODIFY"):
            continue
        data = record["dynamodb"]
        new = plain(data.get("NewImage"))
        old = plain(data.get("OldImage"))
        if is_low(new) and not is_low(old):
            entries.append(build_entry(record, old, new))

    if entries:
        send(entries)
    logger.info(json.dumps({"records": len(event["Records"]), "low_stock_events": len(entries)}))
    return {"emitted": len(entries)}
