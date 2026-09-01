variable "project_name" {
  description = "プロジェクト名（リソース名のプレフィックスに使用）"
  type        = string
  default     = "sre-demo"
}

# Terraformで使用するAWSリージョンを変数として定義
variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1" # 東京リージョン
}

variable "vpc_cidr" {
  description = "VPCのCIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "key_name" {
  description = "your-key-name"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "SSH接続を許可するCIDRブロック（例: 自宅グローバルIP/32）"
  type        = string
}
