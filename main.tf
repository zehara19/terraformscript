resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"
}

#Production VPC
resource "aws_vpc" "prod" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# Public subnets
resource "aws_subnet" "prod_public_1" {
  cidr_block        = "10.0.1.0/24"
  vpc_id            = aws_vpc.prod.id
  availability_zone = var.availability_zones[0]
  tags = {
    Name = "prod-public-1"
  }
}
resource "aws_subnet" "prod_public_2" {
  cidr_block        = "10.0.2.0/24"
  vpc_id            = aws_vpc.prod.id
  availability_zone = var.availability_zones[1]
  tags = {
    Name = "prod-public-2"
  }
}

# Private subnets
resource "aws_subnet" "prod_private_1" {
  cidr_block        = "10.0.3.0/24"
  vpc_id            = aws_vpc.prod.id
  availability_zone = var.availability_zones[0]
  tags = {
    Name = "prod-private-1"
  }
}
resource "aws_subnet" "prod_private_2" {
  cidr_block        = "10.0.4.0/24"
  vpc_id            = aws_vpc.prod.id
  availability_zone = var.availability_zones[1]
  tags = {
    Name = "prod-private-2"
  }
}

# Route tables and association with the subnets
resource "aws_route_table" "prod_public" {
  vpc_id = aws_vpc.prod.id
}
resource "aws_route_table_association" "prod_public_1" {
  route_table_id = aws_route_table.prod_public.id
  subnet_id      = aws_subnet.prod_public_1.id
}
resource "aws_route_table_association" "prod_public_2" {
  route_table_id = aws_route_table.prod_public.id
  subnet_id      = aws_subnet.prod_public_2.id
}

resource "aws_route_table" "prod_private" {
  vpc_id = aws_vpc.prod.id
}
resource "aws_route_table_association" "private_1" {
  route_table_id = aws_route_table.prod_private.id
  subnet_id      = aws_subnet.prod_private_1.id
}
resource "aws_route_table_association" "private_2" {
  route_table_id = aws_route_table.prod_private.id
  subnet_id      = aws_subnet.prod_private_2.id
}

# Internet Gateway for the public subnet
resource "aws_internet_gateway" "prod" {
  vpc_id = aws_vpc.prod.id
}
resource "aws_route" "prod_internet_gateway" {
  route_table_id         = aws_route_table.prod_public.id
  gateway_id             = aws_internet_gateway.prod.id
  destination_cidr_block = "0.0.0.0/0"
}

# NAT gateway
resource "aws_eip" "prod_nat_gateway" {
  vpc                       = true
  associate_with_private_ip = "10.0.0.5"
  depends_on                = [aws_internet_gateway.prod]
}
resource "aws_nat_gateway" "prod" {
  allocation_id = aws_eip.prod_nat_gateway.id
  subnet_id     = aws_subnet.prod_public_1.id
}
resource "aws_route" "prod_nat_gateway" {
  route_table_id         = aws_route_table.prod_private.id
  nat_gateway_id         = aws_nat_gateway.prod.id
  destination_cidr_block = "0.0.0.0/0"
}


# Application Load Balancer for production
resource "aws_lb" "prod" {
  name               = "prod"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.prod_lb.id]
  subnets            = [aws_subnet.prod_public_1.id, aws_subnet.prod_public_2.id]
}

# Target group for backend web application
resource "aws_lb_target_group" "prod_backend" {
  name        = "prod-backend"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.prod.id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 2
    interval            = 5
    matcher             = "200"
  }
}

# Target listener for http:80
resource "aws_lb_listener" "prod_http" {
  load_balancer_arn = aws_lb.prod.id
  port              = "80"
  protocol          = "HTTP"
  depends_on        = [aws_lb_target_group.prod_backend]

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod_backend.arn
  }
}

# Allow traffic from 80 and 443 ports only
resource "aws_security_group" "prod_lb" {
  name        = "prod-lb"
  description = "Controls access to the ALB"
  vpc_id      = aws_vpc.prod.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Production cluster
resource "aws_ecs_cluster" "prod" {
  name = "prod"
}

# Backend web task definition and service
resource "aws_ecs_task_definition" "prod_backend_web" {
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  family = "backend-web"
  container_definitions = templatefile(
    "templates/backend_container.json.tpl",
    {
      region     = var.region
      name       = "prod-backend-web"
      image      = aws_ecr_repository.backend.repository_url
      command    = ["gunicorn", "-w", "3", "-b", ":8000", "django_aws.wsgi:application"]
      log_group  = aws_cloudwatch_log_group.prod_backend.name
      log_stream = aws_cloudwatch_log_stream.prod_backend_web.name
    },
  )
  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.prod_backend_task.arn
}

resource "aws_ecs_service" "prod_backend_web" {
  name                               = "prod-backend-web"
  cluster                            = aws_ecs_cluster.prod.id
  task_definition                    = aws_ecs_task_definition.prod_backend_web.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"

  load_balancer {
    target_group_arn = aws_lb_target_group.prod_backend.arn
    container_name   = "prod-backend-web"
    container_port   = 8000
  }

  network_configuration {
    security_groups  = [aws_security_group.prod_ecs_backend.id]
    subnets          = [aws_subnet.prod_private_1.id, aws_subnet.prod_private_2.id]
    assign_public_ip = false
  }
}

# Security Group
resource "aws_security_group" "prod_ecs_backend" {
  name        = "prod-ecs-backend"
  vpc_id      = aws_vpc.prod.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.prod_lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM roles and policies
resource "aws_iam_role" "prod_backend_task" {
  name = "prod-backend-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "ecs-task-execution"

  assume_role_policy = jsonencode(
    {
      Version = "2012-10-17",
      Statement = [
        {
          Action = "sts:AssumeRole",
          Principal = {
            Service = "ecs-tasks.amazonaws.com"
          },
          Effect = "Allow",
          Sid    = ""
        }
      ]
    }
  )
}

resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Cloudwatch Logs
resource "aws_cloudwatch_log_group" "prod_backend" {
  name              = "prod-backend"
  retention_in_days = var.ecs_prod_backend_retention_days
}

resource "aws_cloudwatch_log_stream" "prod_backend_web" {
  name           = "prod-backend-web"
  log_group_name = aws_cloudwatch_log_group.prod_backend.name
}

resource "aws_sqs_queue" "prod" {
  name                      = "prod-queue"
  receive_wait_time_seconds = 10
  tags = {
    Environment = "production"
  }
}

resource "aws_iam_user" "prod_sqs" {
  name = "prod-sqs-user"
}

resource "aws_iam_user_policy" "prod_sqs" {
  user = aws_iam_user.prod_sqs.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sqs:*",
        ]
        Effect   = "Allow"
        Resource = "arn:aws:sqs:*:*:*"
      },
    ]
  })
}

resource "aws_iam_access_key" "prod_sqs" {
  user = aws_iam_user.prod_sqs.name
}


resource "aws_cloudwatch_log_stream" "prod_backend_worker" {
  name           = "prod-backend-worker"
  log_group_name = aws_cloudwatch_log_group.prod_backend.name
}

resource "aws_cloudwatch_log_stream" "prod_backend_beat" {
  name           = "prod-backend-worker"
  log_group_name = aws_cloudwatch_log_group.prod_backend.name
}

...

# Worker

resource "aws_ecs_task_definition" "prod_backend_worker" {
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  family = "backend-worker"
  container_definitions = templatefile(
    "templates/backend_container.json.tpl",
    merge(
      local.container_vars,
      {
        name       = "prod-backend-worker"
        command    = ["celery", "-A", "django_aws", "worker", "--loglevel", "info"]
        log_stream = aws_cloudwatch_log_stream.prod_backend_worker.name
      },
    )
  )
  depends_on = [aws_sqs_queue.prod, aws_db_instance.prod]
  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.prod_backend_task.arn
}

resource "aws_ecs_service" "prod_backend_worker" {
  name                               = "prod-backend-worker"
  cluster                            = aws_ecs_cluster.prod.id
  task_definition                    = aws_ecs_task_definition.prod_backend_worker.arn
  desired_count                      = 2
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_execute_command             = true

  network_configuration {
    security_groups  = [aws_security_group.prod_ecs_backend.id]
    subnets          = [aws_subnet.prod_private_1.id, aws_subnet.prod_private_2.id]
    assign_public_ip = false
  }
}

# Beat

resource "aws_ecs_task_definition" "prod_backend_beat" {
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  family = "backend-beat"
  container_definitions = templatefile(
    "templates/backend_container.json.tpl",
    merge(
      local.container_vars,
      {
        name       = "prod-backend-beat"
        command    = ["celery", "-A", "django_aws", "beat", "--loglevel", "info"]
        log_stream = aws_cloudwatch_log_stream.prod_backend_beat.name
      },
    )
  )
  depends_on = [aws_sqs_queue.prod, aws_db_instance.prod]
  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.prod_backend_task.arn
}

resource "aws_ecs_service" "prod_backend_beat" {
  name                               = "prod-backend-beat"
  cluster                            = aws_ecs_cluster.prod.id
  task_definition                    = aws_ecs_task_definition.prod_backend_beat.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_execute_command             = true

  network_configuration {
    security_groups  = [aws_security_group.prod_ecs_backend.id]
    subnets          = [aws_subnet.prod_private_1.id, aws_subnet.prod_private_2.id]
    assign_public_ip = false
  }
}

resource "aws_s3_bucket" "prod_media" {
  bucket = var.prod_media_bucket
  acl    = "public-read"

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "PublicReadGetObject"
        Principal = "*"
        Action = [
          "s3:GetObject",
        ]
        Effect   = "Allow"
        Resource = [
          "arn:aws:s3:::${var.prod_media_bucket}",
          "arn:aws:s3:::${var.prod_media_bucket}/*"
        ]
      },
    ]
  })
}


resource "aws_iam_user" "prod_media_bucket" {
  name = "prod-media-bucket"
}

resource "aws_iam_user_policy" "prod_media_bucket" {
  user = aws_iam_user.prod_media_bucket.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:*",
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:s3:::${var.prod_media_bucket}",
          "arn:aws:s3:::${var.prod_media_bucket}/*"
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "prod_media_bucket" {
  user = aws_iam_user.prod_media_bucket.name
}
