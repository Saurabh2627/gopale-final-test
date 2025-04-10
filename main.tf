provider "aws" {
  region = "us-east-1"
}

# VPC
resource "aws_vpc" "gopale_vpc" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = "gopale-vpc" }
}

# Private Subnets
resource "aws_subnet" "gopale_private_subnet_1" {
  vpc_id            = aws_vpc.gopale_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  tags              = { Name = "gopale-private-subnet-1" }
}

resource "aws_subnet" "gopale_private_subnet_2" {
  vpc_id            = aws_vpc.gopale_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags              = { Name = "gopale-private-subnet-2" }
}

# Public Subnets for Load Balancer
resource "aws_subnet" "gopale_public_subnet_1" {
  vpc_id            = aws_vpc.gopale_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"
  tags              = { Name = "gopale-public-subnet-1" }
}

resource "aws_subnet" "gopale_public_subnet_2" {
  vpc_id            = aws_vpc.gopale_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1b"
  tags              = { Name = "gopale-public-subnet-2" }
}

# Internet Gateway
resource "aws_internet_gateway" "gopale_igw" {
  vpc_id = aws_vpc.gopale_vpc.id
  tags   = { Name = "gopale-igw" }
}

# Route Table for Public Subnets
resource "aws_route_table" "gopale_public_rt" {
  vpc_id = aws_vpc.gopale_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gopale_igw.id
  }
  tags = { Name = "gopale-public-rt" }
}

resource "aws_route_table_association" "gopale_public_rt_assoc_1" {
  subnet_id      = aws_subnet.gopale_public_subnet_1.id
  route_table_id = aws_route_table.gopale_public_rt.id
}

resource "aws_route_table_association" "gopale_public_rt_assoc_2" {
  subnet_id      = aws_subnet.gopale_public_subnet_2.id
  route_table_id = aws_route_table.gopale_public_rt.id
}

# NAT Gateway for Private Subnets
resource "aws_eip" "gopale_eip" {
  vpc  = true
  tags = { Name = "gopale-eip" }
}

resource "aws_nat_gateway" "gopale_nat" {
  allocation_id = aws_eip.gopale_eip.id
  subnet_id     = aws_subnet.gopale_public_subnet_1.id
  tags          = { Name = "gopale-nat" }
  depends_on    = [aws_internet_gateway.gopale_igw]
}

resource "aws_route_table" "gopale_private_rt" {
  vpc_id = aws_vpc.gopale_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.gopale_nat.id
  }
  tags = { Name = "gopale-private-rt" }
}

resource "aws_route_table_association" "gopale_private_rt_assoc_1" {
  subnet_id      = aws_subnet.gopale_private_subnet_1.id
  route_table_id = aws_route_table.gopale_private_rt.id
}

resource "aws_route_table_association" "gopale_private_rt_assoc_2" {
  subnet_id      = aws_subnet.gopale_private_subnet_2.id
  route_table_id = aws_route_table.gopale_private_rt.id
}

# Security Group
resource "aws_security_group" "gopale_sg" {
  vpc_id = aws_vpc.gopale_vpc.id
  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # ALB will forward traffic to this port
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "gopale-sg" }
}

# Application Load Balancer
resource "aws_lb" "gopale_alb" {
  name               = "gopale-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.gopale_sg.id]
  subnets            = [aws_subnet.gopale_public_subnet_1.id, aws_subnet.gopale_public_subnet_2.id]
  tags               = { Name = "gopale-alb" }
}

resource "aws_lb_target_group" "gopale_tg" {
  name        = "gopale-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.gopale_vpc.id
  target_type = "ip"
  health_check {
    path                = "/"
    port                = "5000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
  }
}

resource "aws_lb_listener" "gopale_listener" {
  load_balancer_arn = aws_lb.gopale_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gopale_tg.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "gopale_cluster" {
  name = "gopale-final-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "gopale_task" {
  family                   = "gopale-final-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.gopale_ecs_execution_role.arn
  container_definitions    = jsonencode([{
    name  = "gopale-final-api"
    image = "515880899753.dkr.ecr.us-east-1.amazonaws.com/gopale-final-api:latest"
    portMappings = [{
      containerPort = 5000
      hostPort      = 5000
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/gopale-final-task"
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "gopale"
      }
    }
  }])
}

resource "aws_cloudwatch_log_group" "gopale_logs" {
  name = "/ecs/gopale-final-task"
}

# ECS Service
resource "aws_ecs_service" "gopale_service" {
  name            = "gopale-final-service"
  cluster         = aws_ecs_cluster.gopale_cluster.id
  task_definition = aws_ecs_task_definition.gopale_task.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = [aws_subnet.gopale_private_subnet_1.id, aws_subnet.gopale_private_subnet_2.id]
    security_groups  = [aws_security_group.gopale_sg.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.gopale_tg.arn
    container_name   = "gopale-final-api"
    container_port   = 5000
  }
}

# IAM Role for ECS Execution
resource "aws_iam_role" "gopale_ecs_execution_role" {
  name = "gopale-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gopale_ecs_execution_policy" {
  role       = aws_iam_role.gopale_ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "gopale_ecr_policy" {
  role       = aws_iam_role.gopale_ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Autoscaling
resource "aws_appautoscaling_target" "gopale_scaling_target" {
  max_capacity       = 5
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.gopale_cluster.name}/${aws_ecs_service.gopale_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "gopale_scale_out" {
  name               = "gopale-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.gopale_scaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.gopale_scaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.gopale_scaling_target.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = 90
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_out_cooldown = 120
    scale_in_cooldown  = 300
  }
}