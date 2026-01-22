# -----------------------------------------------------------------------------
# OPENSEARCH SERVERLESS
# Vector search collection for RAG capabilities
# -----------------------------------------------------------------------------

resource "aws_opensearchserverless_security_policy" "encryption" {
  name   = "${var.project_name}-encryption"
  type   = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${var.project_name}-vectors"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name   = "${var.project_name}-network"
  type   = "network"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${var.project_name}-vectors"]
    }, {
      ResourceType = "dashboard"
      Resource     = ["collection/${var.project_name}-vectors"]
    }]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_collection" "pluto" {
  name = "${var.project_name}-vectors"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]

  tags = {
    Name = "${var.project_name}-vectors"
  }
}

resource "aws_opensearchserverless_access_policy" "data" {
  name   = "${var.project_name}-data"
  type   = "data"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "index"
      Resource     = ["index/${var.project_name}-vectors/*"]
      Permission   = ["aoss:*"]
    }, {
      ResourceType = "collection"
      Resource     = ["collection/${var.project_name}-vectors"]
      Permission   = ["aoss:*"]
    }]
    Principal = [aws_iam_role.ecs_task.arn]
  }])
}
