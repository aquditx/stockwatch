"""StockWatch products API.

Runs behind API Gateway (HTTP API, payload v2) with a Cognito JWT authorizer.
Roles come from the `cognito:groups` claim:
  owner -> full access
  staff -> read products + adjust stock
"""
import base64
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
GSI_NAME = os.environ.get("GSI_NAME", "gsi1")

OWNER = "owner"
STAFF = "staff"
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# field -> (type, limit)   for str/email the limit is max length, for int it is the minimum value
FIELDS = {
    "name": ("str", 100),
    "sku": ("str", 50),
    "stock": ("int", 0),
    "reorder_threshold": ("int", 0),
    "reorder_qty": ("int", 1),
    "supplier_email": ("email", 254),
}
CREATE_REQUIRED = list(FIELDS)


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# --- helpers ----------------------------------------------------------------

def _json_default(o):
    if isinstance(o, Decimal):
        return int(o) if o == o.to_integral_value() else float(o)
    raise TypeError(f"Not serializable: {type(o)}")


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def get_groups(event):
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    raw = claims.get("cognito:groups", "")
    if isinstance(raw, list):
        return set(raw)
    # HTTP API renders list claims as a string such as "[owner staff]"
    return {g for g in str(raw).strip("[]").replace(",", " ").split() if g}


def require(event, *allowed):
    if not get_groups(event) & set(allowed):
        raise ApiError(403, f"Requires one of these roles: {', '.join(allowed)}")


def parse_body(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        raise ApiError(400, "Body must be valid JSON")
    if not isinstance(body, dict):
        raise ApiError(400, "Body must be a JSON object")
    return body


def path_id(event):
    pid = (event.get("pathParameters") or {}).get("id", "")
    if not pid:
        raise ApiError(400, "Missing product id")
    return pid


def validate(body, required):
    unknown = set(body) - set(FIELDS)
    if unknown:
        raise ApiError(400, f"Unknown fields: {', '.join(sorted(unknown))}")
    missing = [f for f in required if f not in body]
    if missing:
        raise ApiError(400, f"Missing fields: {', '.join(missing)}")

    clean = {}
    for field, value in body.items():
        kind, limit = FIELDS[field]
        if kind == "int":
            if isinstance(value, bool) or not isinstance(value, int) or value < limit:
                raise ApiError(400, f"'{field}' must be an integer >= {limit}")
            clean[field] = value
        else:
            if not isinstance(value, str) or not value.strip() or len(value) > limit:
                raise ApiError(400, f"'{field}' must be a non-empty string up to {limit} chars")
            value = value.strip()
            if kind == "email" and not EMAIL_RE.match(value):
                raise ApiError(400, f"'{field}' must be a valid email address")
            clean[field] = value
    return clean


def key(pid):
    return {"pk": f"PRODUCT#{pid}", "sk": "META"}


def to_api(item):
    hidden = {"pk", "sk", "gsi1pk", "gsi1sk"}
    out = {"product_id": item["pk"].split("#", 1)[1]}
    out.update({k: v for k, v in item.items() if k not in hidden})
    return out


# --- route handlers ---------------------------------------------------------

def list_products(event):
    require(event, OWNER, STAFF)
    params = event.get("queryStringParameters") or {}
    try:
        limit = max(1, min(int(params.get("limit", 50)), 100))
    except ValueError:
        raise ApiError(400, "'limit' must be an integer")

    kwargs = {
        "IndexName": GSI_NAME,
        "KeyConditionExpression": Key("gsi1pk").eq("PRODUCT"),
        "Limit": limit,
    }
    token = params.get("next_token")
    if token:
        try:
            kwargs["ExclusiveStartKey"] = json.loads(base64.urlsafe_b64decode(token))
        except Exception:
            raise ApiError(400, "Invalid next_token")

    res = TABLE.query(**kwargs)
    body = {"items": [to_api(i) for i in res.get("Items", [])]}
    if "LastEvaluatedKey" in res:
        body["next_token"] = base64.urlsafe_b64encode(
            json.dumps(res["LastEvaluatedKey"]).encode()
        ).decode()
    return respond(200, body)


def to_alert(item):
    hidden = {"pk", "sk", "gsi1pk", "gsi1sk"}
    out = {
        "product_id": item["pk"].split("#", 1)[1],
        "alert_id": item["sk"].split("#", 1)[1],
    }
    out.update({k: v for k, v in item.items() if k not in hidden})
    return out


def list_alerts(event):
    """Low-stock alerts written by the notifier, newest first."""
    require(event, OWNER, STAFF)
    params = event.get("queryStringParameters") or {}
    try:
        limit = max(1, min(int(params.get("limit", 50)), 100))
    except ValueError:
        raise ApiError(400, "'limit' must be an integer")

    res = TABLE.query(
        IndexName=GSI_NAME,
        KeyConditionExpression=Key("gsi1pk").eq("ALERT"),
        ScanIndexForward=False,
        Limit=limit,
    )
    return respond(200, {"items": [to_alert(i) for i in res.get("Items", [])]})


def create_product(event):
    require(event, OWNER)
    fields = validate(parse_body(event), CREATE_REQUIRED)
    pid = str(uuid.uuid4())
    ts = now()
    item = {
        **key(pid),
        "gsi1pk": "PRODUCT",
        "gsi1sk": f"{fields['name'].lower()}#{pid}",
        **fields,
        "created_at": ts,
        "updated_at": ts,
    }
    TABLE.put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
    return respond(201, to_api(item))


def get_product(event):
    require(event, OWNER, STAFF)
    res = TABLE.get_item(Key=key(path_id(event)))
    if "Item" not in res:
        raise ApiError(404, "Product not found")
    return respond(200, to_api(res["Item"]))


def update_product(event):
    require(event, OWNER)
    pid = path_id(event)
    fields = validate(parse_body(event), required=[])
    if not fields:
        raise ApiError(400, "Provide at least one field to update")

    names, values = {}, {":updated": now()}
    sets = ["updated_at = :updated"]
    for i, (field, value) in enumerate(fields.items()):
        names[f"#f{i}"] = field
        values[f":v{i}"] = value
        sets.append(f"#f{i} = :v{i}")
    if "name" in fields:  # keep the list index sorted by name
        sets.append("gsi1sk = :gsk")
        values[":gsk"] = f"{fields['name'].lower()}#{pid}"

    try:
        res = TABLE.update_item(
            Key=key(pid),
            UpdateExpression="SET " + ", ".join(sets),
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
            ConditionExpression="attribute_exists(pk)",
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(404, "Product not found")
        raise
    return respond(200, to_api(res["Attributes"]))


def delete_product(event):
    require(event, OWNER)
    pid = path_id(event)
    try:
        TABLE.delete_item(Key=key(pid), ConditionExpression="attribute_exists(pk)")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(404, "Product not found")
        raise
    return respond(200, {"deleted": pid})


def adjust_stock(event):
    """Atomic stock change: {"delta": -3} sells 3, {"delta": 10} restocks 10."""
    require(event, OWNER, STAFF)
    pid = path_id(event)
    delta = parse_body(event).get("delta")
    if isinstance(delta, bool) or not isinstance(delta, int) or delta == 0 or abs(delta) > 100000:
        raise ApiError(400, "'delta' must be a non-zero integer (max 100000 in either direction)")

    condition = "attribute_exists(pk)"
    values = {":d": delta, ":updated": now()}
    if delta < 0:
        condition += " AND stock >= :need"  # never let stock go negative
        values[":need"] = -delta

    try:
        res = TABLE.update_item(
            Key=key(pid),
            UpdateExpression="SET stock = stock + :d, updated_at = :updated",
            ConditionExpression=condition,
            ExpressionAttributeValues=values,
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        exists = "Item" in TABLE.get_item(Key=key(pid), ProjectionExpression="pk")
        if not exists:
            raise ApiError(404, "Product not found")
        raise ApiError(409, "Insufficient stock for that adjustment")
    return respond(200, to_api(res["Attributes"]))


ROUTES = {
    "GET /products": list_products,
    "GET /alerts": list_alerts,
    "POST /products": create_product,
    "GET /products/{id}": get_product,
    "PUT /products/{id}": update_product,
    "DELETE /products/{id}": delete_product,
    "POST /products/{id}/stock": adjust_stock,
}


def handler(event, context):
    route = event.get("routeKey")
    try:
        fn = ROUTES.get(route)
        if fn is None:
            raise ApiError(404, "Route not found")
        return fn(event)
    except ApiError as e:
        logger.info(json.dumps({"route": route, "status": e.status, "error": e.message}))
        return respond(e.status, {"error": e.message})
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return respond(409, {"error": "Conflict"})
        logger.exception("DynamoDB error on %s", route)
        return respond(500, {"error": "Internal server error"})
    except Exception:
        logger.exception("Unhandled error on %s", route)
        return respond(500, {"error": "Internal server error"})
