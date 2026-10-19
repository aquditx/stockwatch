# Single-table design.
#   Product item:  pk = PRODUCT#<id>, sk = META
#   gsi1 lists all products, sorted by name:  gsi1pk = PRODUCT, gsi1sk = <name>#<id>
# Later phases add more item types (purchase orders, alerts) to the same table.

resource "aws_dynamodb_table" "main" {
  name         = "${var.project}-main"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "gsi1pk"
    type = "S"
  }

  attribute {
    name = "gsi1sk"
    type = "S"
  }

  global_secondary_index {
    name            = "gsi1"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
  }

  # Streams power the low-stock detection pipeline in Phase 2.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
