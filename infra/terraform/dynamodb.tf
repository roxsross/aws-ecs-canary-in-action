/* ---------------------------------------------------------------------------
   Single table shared by every task of both tracks. This is what turns the
   dashboard from "what this container saw" into a global view of the rollout.

     pk=AGG    sk=<track>#<version>   counters per track and version
     pk=TS     sk=<minute>#<track>    per minute buckets for the chart
     pk=HIT    sk=<epochMs>#<rand>    recent request feed (expires via TTL)
     pk=CHAOS  sk=<track>             fault injection state, polled by all tasks
   --------------------------------------------------------------------------- */

resource "aws_dynamodb_table" "traffic" {
  name         = local.table_name
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

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false # disposable demo data
  }

  server_side_encryption {
    enabled = true # AWS owned key, no extra cost
  }

  tags = { Name = local.table_name }
}
