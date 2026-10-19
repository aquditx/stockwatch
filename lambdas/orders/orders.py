"""Purchase-order workflow code.

Two Lambda entry points live in this file (deployed as two functions):
  task_handler  called by the Step Functions state machine
                (acquire lock, request approval, send to supplier, mark expired)
  api_handler   behind API Gateway: list orders, view one, approve, reject

Order lifecycle (status field):
  PENDING_APPROVAL -> APPROVED -> SENT_TO_SUPPLIER
                   -> REJECTED
                   -> EXPIRED   (nobody answered within 24 hours)
"""
import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
GSI_NAME = os.environ.get("GSI_NAME", "gsi1")
TOPIC_ARN = os.environ.get("TOPIC_ARN", "")
SFN = boto3.client("stepfunctions")
SNS = boto3.client("sns")

OWNER = "owner"
STAFF = "staff"
LOCK_SECONDS = 25 * 3600  # slightly longer than the 24 h approval window
HIDDEN = {"pk", "sk", "gsi1pk", "gsi1sk", "task_token"}
STATUS = {"#s": "status"}  # "status" is a DynamoDB reserved word


# --- shared helpers -----------------------------------------------------------

def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def cond_failed(err):
    return err.response["Error"]["Code"] == "ConditionalCheckFailedException"


def po_key(po_id):
    return {"pk": f"PO#{po_id}", "sk": "META"}


def lock_key(product_id):
    return {"pk": f"PRODUCT#{product_id}", "sk": "OPENPO"}


def release_lock(product_id, po_id):
    """Free the one-open-order-per-product lock, but only if this order owns it."""
    try:
        TABLE.delete_item(
            Key=lock_key(product_id),
            ConditionExpression="po_id = :po",
            ExpressionAttributeValues={":po": po_id},
        )
    except ClientError as e:
        if not cond_failed(e):
            raise


def to_api(item):
    out = {"po_id": item["pk"].split("#", 1)[1]}
    out.update({k: v for k, v in item.items() if k not in HIDDEN})
    return out


# --- Step Functions tasks -----------------------------------------------------

def acquire_lock(event):
    """Allow only one open order per product. Safe to call again for the same order."""
    detail = event["detail"]
    now = int(time.time())
    try:
        TABLE.put_item(
            Item={
                **lock_key(detail["product_id"]),
                "po_id": event["po_id"],
                "expires_at": now + LOCK_SECONDS,
            },
            ConditionExpression="attribute_not_exists(pk) OR expires_at < :now OR po_id = :po",
            ExpressionAttributeValues={":now": now, ":po": event["po_id"]},
        )
        return {"proceed": True}
    except ClientError as e:
        if cond_failed(e):
            logger.info(json.dumps({"skipped": "order already open", "product_id": detail["product_id"]}))
            return {"proceed": False}
        raise


def request_approval(event):
    """Create the order, store the task token, and ask the owner to decide.

    The state machine pauses on this task until the API calls SendTaskSuccess or
    SendTaskFailure with the token saved here.
    """
    d = event["detail"]
    po_id = event["po_id"]
    created = now_iso()
    name = str(d.get("name") or "Unknown product")
    item = {
        **po_key(po_id),
        "gsi1pk": "PO",
        "gsi1sk": f"{created}#{po_id}",
        "product_id": d["product_id"],
        "product_name": name,
        "sku": d.get("sku"),
        "quantity": d.get("reorder_qty"),
        "supplier_email": d.get("supplier_email"),
        "stock_at_trigger": d.get("stock"),
        "reorder_threshold": d.get("reorder_threshold"),
        "status": "PENDING_APPROVAL",
        "created_at": created,
        "task_token": event["task_token"],
    }
    TABLE.put_item(Item=item)

    SNS.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"Approve purchase order: {d.get('reorder_qty')} x {name[:50]}",
        Message=(
            f"Order ID:   {po_id}\n"
            f"Product:    {name} (SKU {d.get('sku')})\n"
            f"Quantity:   {d.get('reorder_qty')}\n"
            f"Supplier:   {d.get('supplier_email')}\n"
            f"Stock now:  {d.get('stock')} (threshold {d.get('reorder_threshold')})\n\n"
            f"Approve or reject it in the app, or call POST /orders/{po_id}/approve.\n"
            f"If nobody answers within 24 hours the order expires.\n"
        ),
    )
    return {"created": True}


def mark_expired(event):
    po_id = event["po_id"]
    try:
        TABLE.update_item(
            Key=po_key(po_id),
            UpdateExpression="SET #s = :expired, decided_at = :t REMOVE task_token",
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames=STATUS,
            ExpressionAttributeValues={
                ":expired": "EXPIRED",
                ":pending": "PENDING_APPROVAL",
                ":t": now_iso(),
            },
        )
    except ClientError as e:
        if not cond_failed(e):
            raise
    release_lock(event["detail"]["product_id"], po_id)
    return {"expired": True}


def send_to_supplier(event):
    """Email the supplier. Demo note: SNS delivers to the subscribed owner address;
    swap this publish for SES to email real suppliers."""
    po_id = event["po_id"]
    item = TABLE.get_item(Key=po_key(po_id)).get("Item")
    if not item:
        raise ValueError(f"Order {po_id} not found")
    if item["status"] == "SENT_TO_SUPPLIER":
        return {"sent": True}  # retry after success

    SNS.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"Purchase order sent: {item['quantity']} x {str(item['product_name'])[:50]}",
        Message=(
            f"To:         {item.get('supplier_email')}\n"
            f"Order ID:   {po_id}\n"
            f"Product:    {item['product_name']} (SKU {item.get('sku')})\n"
            f"Quantity:   {item['quantity']}\n"
            f"Approved:   {item.get('decided_at')} by {item.get('decided_by')}\n"
        ),
    )
    TABLE.update_item(
        Key=po_key(po_id),
        UpdateExpression="SET #s = :sent, sent_at = :t",
        ExpressionAttributeNames=STATUS,
        ExpressionAttributeValues={":sent": "SENT_TO_SUPPLIER", ":t": now_iso()},
    )
    return {"sent": True}


ACTIONS = {
    "acquire_lock": acquire_lock,
    "request_approval": request_approval,
    "mark_expired": mark_expired,
    "send_to_supplier": send_to_supplier,
}


def task_handler(event, context):
    fn = ACTIONS.get(event.get("action"))
    if fn is None:
        raise ValueError(f"Unknown action: {event.get('action')}")
    return fn(event)


# --- Orders API -----------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def _json_default(o):
    if hasattr(o, "to_integral_value"):
        return int(o) if o == o.to_integral_value() else float(o)
    raise TypeError(f"Not serializable: {type(o)}")


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }


def claims(event):
    return (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )


def get_groups(event):
    raw = claims(event).get("cognito:groups", "")
    if isinstance(raw, list):
        return set(raw)
    return {g for g in str(raw).strip("[]").replace(",", " ").split() if g}


def require(event, *allowed):
    if not get_groups(event) & set(allowed):
        raise ApiError(403, f"Requires one of these roles: {', '.join(allowed)}")


def path_id(event):
    po_id = (event.get("pathParameters") or {}).get("id", "")
    if not po_id:
        raise ApiError(400, "Missing order id")
    return po_id


def list_orders(event):
    require(event, OWNER, STAFF)
    params = event.get("queryStringParameters") or {}
    try:
        limit = max(1, min(int(params.get("limit", 50)), 100))
    except ValueError:
        raise ApiError(400, "'limit' must be an integer")
    res = TABLE.query(
        IndexName=GSI_NAME,
        KeyConditionExpression=Key("gsi1pk").eq("PO"),
        ScanIndexForward=False,  # newest first
        Limit=limit,
    )
    return respond(200, {"items": [to_api(i) for i in res.get("Items", [])]})


def get_order(event):
    require(event, OWNER, STAFF)
    item = TABLE.get_item(Key=po_key(path_id(event))).get("Item")
    if not item:
        raise ApiError(404, "Order not found")
    return respond(200, to_api(item))


def decide(event, approve):
    require(event, OWNER)
    po_id = path_id(event)
    key = po_key(po_id)
    item = TABLE.get_item(Key=key).get("Item")
    if not item:
        raise ApiError(404, "Order not found")
    if item["status"] != "PENDING_APPROVAL":
        raise ApiError(409, f"Order is already {item['status']}")

    c = claims(event)
    who = c.get("email") or c.get("sub") or "unknown"
    token = item["task_token"]
    new_status = "APPROVED" if approve else "REJECTED"

    try:
        res = TABLE.update_item(
            Key=key,
            UpdateExpression="SET #s = :new, decided_at = :t, decided_by = :who REMOVE task_token",
            ConditionExpression="#s = :pending",  # blocks double approval
            ExpressionAttributeNames=STATUS,
            ExpressionAttributeValues={
                ":new": new_status,
                ":pending": "PENDING_APPROVAL",
                ":t": now_iso(),
                ":who": who,
            },
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if cond_failed(e):
            raise ApiError(409, "Order was already decided")
        raise

    release_lock(item["product_id"], po_id)

    try:
        if approve:
            SFN.send_task_success(taskToken=token, output=json.dumps({"approved_by": who}))
        else:
            SFN.send_task_failure(taskToken=token, error="Rejected", cause=f"Rejected by {who}")
    except ClientError:
        logger.exception("Could not resume workflow for %s", po_id)
        TABLE.update_item(  # put the order back so it can be decided again
            Key=key,
            UpdateExpression="SET #s = :pending, task_token = :tok REMOVE decided_at, decided_by",
            ExpressionAttributeNames=STATUS,
            ExpressionAttributeValues={":pending": "PENDING_APPROVAL", ":tok": token},
        )
        raise ApiError(502, "Could not resume the workflow; the order is still pending")

    return respond(200, to_api(res["Attributes"]))


ROUTES = {
    "GET /orders": list_orders,
    "GET /orders/{id}": get_order,
    "POST /orders/{id}/approve": lambda e: decide(e, True),
    "POST /orders/{id}/reject": lambda e: decide(e, False),
}


def api_handler(event, context):
    route = event.get("routeKey")
    try:
        fn = ROUTES.get(route)
        if fn is None:
            raise ApiError(404, "Route not found")
        return fn(event)
    except ApiError as e:
        logger.info(json.dumps({"route": route, "status": e.status, "error": e.message}))
        return respond(e.status, {"error": e.message})
    except Exception:
        logger.exception("Unhandled error on %s", route)
        return respond(500, {"error": "Internal server error"})
