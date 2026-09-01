# ===============================
# AWSプロバイダーの設定
# ===============================
# AWSを使うことをTerraformに教える設定
# リージョンは変数 aws_region から取ってる（今回は東京リージョン）
provider "aws" {
  region = var.aws_region # 東京リージョンを変数で指定（ap-northeast-1）
}

# ===============================
# VPC（仮想ネットワーク）の作成
# ===============================
resource "aws_vpc" "main" {
  # 学習用としてCIDRは /16 を指定（変数で定義）
  cidr_block = var.vpc_cidr

  # VPC内で名前解決（DNS）を使えるようにする
  enable_dns_support = true

  # EC2などに自動でホスト名を付けたいので有効化
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ===============================
# パブリックサブネットの作成（AZ a）
# ===============================
resource "aws_subnet" "public_1" {
  vpc_id = aws_vpc.main.id  # 作成したVPCにこのサブネットを紐付ける

  # サブネットのIP範囲を設定。/24で小さめに区切って管理しやすく
  cidr_block = "10.0.1.0/24"

  # 東京リージョンのaゾーンに配置（可用性向上を考慮してマルチAZを意識）
  availability_zone = "${var.aws_region}a"

  # EC2起動時に自動でパブリックIPを付与 → SSHやHTTPアクセスがすぐ可能に
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-subnet-1"
  }
}

# ===============================
# パブリックサブネットの作成（AZ c）
# ===============================
resource "aws_subnet" "public_2" {
  vpc_id = aws_vpc.main.id  # 同じVPCに属するサブネットとして紐付け

  # 2つ目のAZ用にCIDRを分割（/24）して、IPアドレスの重複を避けつつ整理
  cidr_block = "10.0.2.0/24"

  # 東京リージョンのcゾーンに配置。学習用途ながらマルチAZ構成を意識
  availability_zone = "${var.aws_region}c"

  # EC2に自動でパブリックIPを付与 → SSHやWebアクセスがすぐ可能になるように
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-subnet-2"
  }
}

# ===============================
# インターネットゲートウェイの作成
# ===============================
# EC2などのリソースが外部（インターネット）と通信できるようにするために、
# Internet Gateway（IGW）を作成してVPCにアタッチ。
# これがないと、パブリックIPを持っていてもインターネットには接続できない。
# Webアクセスやyum/dnfによるパッケージインストールにも必要な構成。
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id  # 作成済みのVPCにインターネットゲートウェイを接続

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ===============================
# パブリックサブネット用のルートテーブル作成
# ===============================
# VPC内のサブネットから外部へ向かう通信の経路を定義。
# インターネットゲートウェイに向けることで、
# 対象サブネットのリソースがインターネットと通信できるようになる。
# 例：EC2インスタンスがWebアクセスやアップデートなど外部と通信可能になる。
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id  # 対象VPCにルートテーブルを関連付け

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project_name}-rt"
  }
}

# ===============================
# 各パブリックサブネットとのルートテーブル関連付け
# ===============================
# public_1 サブネットを上記ルートテーブルに紐づける。
# このサブネット内のEC2などがインターネットに出られるようになります。
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

# 同様に public_2 サブネットも関連付け。
# マルチAZ構成を前提に、複数サブネットを同じルートテーブルに接続。
# → 将来的に冗長構成（高可用性）へスムーズに移行しやすい設計を意識。
resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# ===============================
# Security Group（セキュリティグループ）の作成
# ===============================
# セキュリティグループ（Webサーバー用）
# SSHとHTTPだけ許可。送信は全部OK。

resource "aws_security_group" "web_sg" {
  name   = "${var.project_name}-web-sg"
  vpc_id = aws_vpc.main.id

  # インバウンドルール（受信）
  # ポート22 (SSH) 
  # 学習環境用に設定。
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]  
  }

  # ポート80 (HTTP) 
  # Webサービスとして外部公開するため
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # アウトバウンドルール（送信）
  # 全トラフィックを外部に許可
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"         
    cidr_blocks = ["0.0.0.0/0"]  
  }

  tags = {
    Name = "${var.project_name}-web-sg"
  }
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ===============================
# EC2インスタンス（1台目）
# ===============================
# AMI IDはリージョンや時期によって変わるため、ハードコードせず
# 常に最新のAmazon Linux 2 AMIを取得する設計とした。
resource "aws_instance" "web" {
  ami                          = data.aws_ami.amazon_linux_2.id
  instance_type                = "t2.micro"
  subnet_id                    = aws_subnet.public_1.id
  key_name                     = var.key_name
  vpc_security_group_ids       = [aws_security_group.web_sg.id]
  associate_public_ip_address  = true

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install nginx1 -y
              systemctl start nginx
              systemctl enable nginx
              EOF

  tags = {
    Name = "${var.project_name}-ec2"
  }
}

# ===============================
# EC2インスタンス（2台目）
# ===============================
# パブリックサブネット（public_2）内に配置し、Nginx をインストール・起動する構成。
# Web サーバー用のセキュリティグループを適用し、外部アクセス（80/22番）も許可。
resource "aws_instance" "web_2" {
  ami                          = data.aws_ami.amazon_linux_2.id
  instance_type                = "t2.micro"
  subnet_id                    = aws_subnet.public_2.id
  key_name                     = var.key_name
  vpc_security_group_ids       = [aws_security_group.web_sg.id]
  associate_public_ip_address  = true

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install nginx1 -y
              systemctl start nginx
              systemctl enable nginx
              EOF

  tags = {
    Name = "${var.project_name}-ec2-2"
  }
}

# -----------------------------------------
# Application Load Balancer（ALB）の作成
# -----------------------------------------
# 今回は、外部（インターネット）からアクセスできるパブリックALBとして構成。
# WebサーバーへのHTTPリクエストを分散するために使用。
resource "aws_lb" "web_alb" {
  name = "${var.project_name}-alb"

  # パブリックALBとして作成（外部からアクセス可能）
  internal           = false

  # HTTP/HTTPSを扱う。
  load_balancer_type = "application"

  # ALBを複数AZ（public_1, public_2）に配置して高可用性を確保
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  security_groups    = [aws_security_group.web_sg.id]

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# -----------------------------------------
# ターゲットグループの作成
# EC2インスタンスへのルーティング定義
# -----------------------------------------
resource "aws_lb_target_group" "web_tg" {
  name     = "${var.project_name}-tg"
  port     = 80 # Webサーバー用のポート
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # ヘルスチェックの設定（ALBが対象のEC2を監視）
  health_check {
    path     = "/"
    protocol = "HTTP"
  }

  tags = {
    Name = "${var.project_name}-tg"
  }
}

# -----------------------------------------
# ALBのリスナー設定
# 80番ポートで受けたリクエストをターゲットグループに転送
# -----------------------------------------
resource "aws_lb_listener" "web_listener" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# -----------------------------------------
# ALBのリスナー設定
# 80番ポートで受けたリクエストをターゲットグループに転送
# -----------------------------------------
resource "aws_lb_target_group_attachment" "web_attach" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web.id # 1台目のWebサーバー
  port             = 80
}

resource "aws_lb_target_group_attachment" "web_2_attach" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web_2.id # 2台目のWebサーバー
  port             = 80
}
