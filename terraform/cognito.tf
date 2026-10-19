resource "aws_cognito_user_pool" "main" {
  name                     = "${var.project}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Only admins create users: no public sign-up on a business inventory system.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH", # handy for CLI smoke tests; drop for production
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 7

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_group" "owner" {
  name         = "owner"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Can manage products, thresholds and approve purchase orders"
}

resource "aws_cognito_user_group" "staff" {
  name         = "staff"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Can view products and adjust stock"
}
