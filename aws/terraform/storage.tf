# -----------------------------------------------------------------------------
# STORAGE
# EFS (Elastic File System) and ECR (Elastic Container Registry)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ECR REPOSITORIES
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "pluto" {
  for_each = local.ecr_repos

  name = each.value

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true

  tags = {
    Name = "${var.project_name}-${each.key}"
  }
}

# -----------------------------------------------------------------------------
# EFS (Elastic File System)
# -----------------------------------------------------------------------------

resource "aws_efs_file_system" "pluto" {
  encrypted = true

  tags = {
    Name = "${var.project_name}-efs"
  }
}

resource "aws_efs_mount_target" "pluto" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.pluto.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "openwebui" {
  file_system_id = aws_efs_file_system.pluto.id

  root_directory {
    path = "/openwebui"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name = "${var.project_name}-openwebui"
  }
}
