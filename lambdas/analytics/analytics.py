"""Sales analytics. Runs inside the VPC and talks to the private Postgres database.

  load_handler: DynamoDB stream -> one row per sale in Postgres (also: {"action": "seed"})
  api_handler:  GET /forecast   -> days of stock left and a suggested order size
"""
import json
import math
import os
import ssl
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))

import boto3  # noqa: E402
import pg8000.native  # noqa: E402

TABLE = os.environ["TABLE_NAME"]
DDB = boto3.client("dynamodb")

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS sales (
         id bigserial PRIMARY KEY,
         event_id text UNIQUE NOT NULL,
         product_id text NOT NULL,
         product_name text NOT NULL,
         qty integer NOT NULL,
         sold_at timestamptz NOT NULL DEFAULT now())""",
    "CREATE INDEX IF NOT EXISTS sales_product_time ON sales (product_id, sold_at)",
]

_conn = None


def db():
    global _conn
    if _conn is None:
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
        creds = json.loads(secret["SecretString"])
        # Encrypted in transit. The RDS CA bundle is not shipped with Lambda, so the
        # certificate is not verified (see README, known limits).
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        conn = pg8000.native.Connection(
            creds["username"],
            password=creds["password"],
            host=os.environ["DB_HOST"],
            database=os.environ["DB_NAME"],
            ssl_context=ctx,
            timeout=10,
        )
        for stmt in SCHEMA:
            conn.run(stmt)
        _conn = conn
    return _conn


def run(sql, **params):
    global _conn
    try:
        return db().run(sql, **params)
    except (pg8000.exceptions.InterfaceError, OSError):
        _conn = None  # reconnect on the next call
        raise


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def products():
    out = []
    kwargs = {
        "TableName": TABLE,
        "IndexName": "gsi1",
        "KeyConditionExpression": "gsi1pk = :p",
        "ExpressionAttributeValues": {":p": {"S": "PRODUCT"}},
    }
    while True:
        res = DDB.query(**kwargs)
        for item in res.get("Items", []):
            out.append({
                "product_id": item["pk"]["S"].split("#", 1)[1],
                "name": item.get("name", {}).get("S", ""),
                "stock": int(item.get("stock", {}).get("N", "0")),
                "reorder_qty": int(item.get("reorder_qty", {}).get("N", "0")),
            })
        if "LastEvaluatedKey" not in res:
            return out
        kwargs["ExclusiveStartKey"] = res["LastEvaluatedKey"]


# --- DynamoDB stream -> Postgres ---------------------------------------------

def record_sales(records):
    saved = 0
    for rec in records:
        if rec.get("eventName") != "MODIFY":
            continue
        d = rec["dynamodb"]
        try:
            before = int(d["OldImage"]["stock"]["N"])
            after = int(d["NewImage"]["stock"]["N"])
        except KeyError:
            continue
        sold = before - after
        if sold <= 0:
            continue  # restocks and edits are not sales
        run(
            "INSERT INTO sales (event_id, product_id, product_name, qty) "
            "VALUES (:e, :p, :n, :q) ON CONFLICT (event_id) DO NOTHING",
            e=rec["eventID"],
            p=d["Keys"]["pk"]["S"].split("#", 1)[1],
            n=d["NewImage"].get("name", {}).get("S", ""),
            q=sold,
        )
        saved += 1
    return saved


def seed(days=14):
    """Backfill believable sales history so the forecast has something to work with."""
    now = datetime.now(timezone.utc)
    created = 0
    for p in products():
        base = 2 + (sum(ord(c) for c in p["product_id"]) % 4)  # 2-5 a day
        for back in range(1, days + 1):
            qty = max(1, base + (back * 7 + len(p["name"])) % 3 - 1)
            res = run(
                "INSERT INTO sales (event_id, product_id, product_name, qty, sold_at) "
                "VALUES (:e, :p, :n, :q, :t) ON CONFLICT (event_id) DO NOTHING RETURNING id",
                e=f"seed-{p['product_id']}-{back}",
                p=p["product_id"],
                n=p["name"],
                q=qty,
                t=now - timedelta(days=back, hours=3),
            )
            created += len(res)
    return created


def load_handler(event, context):
    if event.get("action") == "seed":
        return {"seeded": seed(int(event.get("days", 14)))}
    return {"saved": record_sales(event.get("Records", []))}


# --- GET /forecast -----------------------------------------------------------

def forecast():
    rows = run(
        "SELECT product_id, COALESCE(SUM(qty), 0) FROM sales "
        "WHERE sold_at > now() - interval '7 days' GROUP BY product_id"
    )
    sold = {pid: int(total) for pid, total in rows}
    items = []
    for p in products():
        sold_7d = sold.get(p["product_id"], 0)
        avg = sold_7d / 7
        items.append({
            "product_id": p["product_id"],
            "name": p["name"],
            "stock": p["stock"],
            "sold_7d": sold_7d,
            "avg_daily": round(avg, 1),
            "days_left": round(p["stock"] / avg, 1) if avg > 0 else None,
            "suggested_qty": math.ceil(avg * 14) if avg > 0 else p["reorder_qty"],
        })
    items.sort(key=lambda i: (i["days_left"] is None, i["days_left"] or 0))
    return items


def api_handler(event, context):
    try:
        return respond(200, {
            "items": forecast(),
            "generated_at": datetime.now(timezone.utc).isoformat(),
        })
    except Exception as exc:  # noqa: BLE001
        print(f"forecast failed: {exc!r}")
        return respond(500, {"error": "Forecast is unavailable. Try again in a minute."})
