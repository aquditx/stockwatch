"""Nightly report. Runs as an ECS Fargate task (the script is passed in as an env var).

Reads sales history from Postgres and current stock from DynamoDB, stores one row per
product in daily_report, and emails a summary through SNS.
"""
import math
import os
import ssl
from datetime import date

import boto3
import pg8000.native

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
conn = pg8000.native.Connection(
    os.environ["DB_USER"],
    password=os.environ["DB_PASSWORD"],
    host=os.environ["DB_HOST"],
    database=os.environ["DB_NAME"],
    ssl_context=ctx,
    timeout=10,
)
conn.run("""CREATE TABLE IF NOT EXISTS sales (
              id bigserial PRIMARY KEY, event_id text UNIQUE NOT NULL, product_id text NOT NULL,
              product_name text NOT NULL, qty integer NOT NULL, sold_at timestamptz NOT NULL DEFAULT now())""")
conn.run("""CREATE TABLE IF NOT EXISTS daily_report (
              report_date date NOT NULL, product_id text NOT NULL, name text NOT NULL,
              sold_7d integer NOT NULL, avg_daily numeric NOT NULL, stock integer NOT NULL,
              days_left numeric, suggested_qty integer NOT NULL,
              PRIMARY KEY (report_date, product_id))""")

sold = {
    pid: int(total)
    for pid, total in conn.run(
        "SELECT product_id, COALESCE(SUM(qty), 0) FROM sales "
        "WHERE sold_at > now() - interval '7 days' GROUP BY product_id"
    )
}

ddb = boto3.client("dynamodb")
res = ddb.query(
    TableName=os.environ["TABLE_NAME"],
    IndexName="gsi1",
    KeyConditionExpression="gsi1pk = :p",
    ExpressionAttributeValues={":p": {"S": "PRODUCT"}},
)

today = date.today()
lines = []
for item in res.get("Items", []):
    pid = item["pk"]["S"].split("#", 1)[1]
    name = item.get("name", {}).get("S", pid)
    stock = int(item.get("stock", {}).get("N", "0"))
    reorder_qty = int(item.get("reorder_qty", {}).get("N", "0"))
    s7 = sold.get(pid, 0)
    avg = s7 / 7
    days_left = round(stock / avg, 1) if avg > 0 else None
    suggested = math.ceil(avg * 14) if avg > 0 else reorder_qty
    conn.run(
        "INSERT INTO daily_report VALUES (:d, :p, :n, :s7, :a, :st, :dl, :q) "
        "ON CONFLICT (report_date, product_id) DO UPDATE SET sold_7d = :s7, avg_daily = :a, "
        "stock = :st, days_left = :dl, suggested_qty = :q",
        d=today, p=pid, n=name, s7=s7, a=round(avg, 2), st=stock, dl=days_left, q=suggested,
    )
    when = f"{days_left} days left" if days_left is not None else "no recent sales"
    lines.append((days_left if days_left is not None else 1e9, f"- {name}: {stock} in stock, {when}, suggest ordering {suggested}"))

lines.sort()
body = "\n".join(text for _, text in lines) or "No products yet."
boto3.client("sns").publish(
    TopicArn=os.environ["TOPIC_ARN"],
    Subject=f"StockWatch daily report {today.isoformat()}",
    Message=f"Stock cover based on the last 7 days of sales (soonest to run out first):\n\n{body}",
)
print(f"report written for {len(lines)} products")
