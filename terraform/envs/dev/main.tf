# 0. 테라폼 백엔드 설정 (기록장을 S3에 저장하여 장소 불문 작업 가능)
terraform {
  backend "s3" {
    bucket         = "my-devops-project-tfstate-dlwotjd" # 아까 만든 버킷 이름
    key            = "terraform/state/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "terraform-up-and-running-locks"
    encrypt        = true
  }
}

# 1. AWS 프로바이더 설정
provider "aws" {
  region = "ap-northeast-2" # 서울 리전
}

# 2. 테라폼 상태를 저장할 S3 버킷 생성
resource "aws_s3_bucket" "terraform_state" {
  bucket = "my-devops-project-tfstate-dlwotjd"

  lifecycle {
    prevent_destroy = true
  }
}

# 3. 버전 관리 활성화
resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 4. 상태 잠금을 위한 DynamoDB 테이블
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-up-and-running-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
# 5. VPC 생성 (가상 네트워크의 가장 큰 울타리)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "my-devops-vpc"
  }
}

# 6. Public Subnet 생성 (서버가 위치할 구역)
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # 이 구역에 생기는 서버는 공인 IP를 가짐
  availability_zone       = "ap-northeast-2a"

  tags = {
    Name = "my-public-subnet"
  }
}

# 7. Internet Gateway 생성 (인터넷과 연결되는 대문)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "my-vpc-igw"
  }
}

# 8. Route Table 생성 (길 찾기 표)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"                 # 모든 외부 트래픽은
    gateway_id = aws_internet_gateway.igw.id # 대문(IGW)으로 보낸다
  }

  tags = {
    Name = "my-public-rt"
  }
}

# 9. Subnet과 Route Table 연결
resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 10-0. 최신 Ubuntu 24.04 AMI ID 자동으로 찾아오기
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Ubuntu 공식 제작사)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# 10. 보안 그룹 설정 (방화벽)
# 이 섹션은 서버로 들어오고 나가는 모든 네트워크 통로를 관리합니다.
resource "aws_security_group" "k3s_sg" {
  name        = "k3s-server-sg"
  description = "Security group for K3s and Argo CD access"
  vpc_id      = aws_vpc.main.id

  # 10-1. SSH 접속용 (22번 포트)
  # Ansible 및 터미널 접속을 위한 통로입니다.
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 10-2. HTTP 웹 서비스용 (80번 포트)
  # 일반적인 웹 접속을 처리합니다.
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 10-3. HTTPS 보안 웹용 (443번 포트)
  # 보안이 강화된 웹 접속을 처리합니다.
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 10-4. K3s API 서버용 (6443번 포트)
  # 로컬(Codespaces)에서 kubectl 명령어를 날릴 때 사용하는 통로입니다.
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 10-5. Argo CD 및 NodePort 서비스용 (30000-32767 포트)
  # 쿠버네티스 서비스를 외부로 노출할 때 사용하는 예약된 포트 범위입니다.
  # 현재 Argo CD 접속을 위해 이 범위가 반드시 열려 있어야 합니다.
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 10-6. 아웃바운드 규칙 (모든 포트)
  # 서버에서 인터넷으로 나가는 모든 요청을 허용합니다. (업데이트 및 패키지 다운로드용)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 11. EC2 인스턴스 생성 (데이터 소스 사용)
resource "aws_instance" "k3s_server" {
  # 10-1에서 찾은 AMI ID를 동적으로 할당합니다.
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"

  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.k3s_sg.id]
  associate_public_ip_address = true
  key_name                    = "my-devops-key"

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "k3s-main-server"
  }
}

# 12. 접속을 위한 결과값 출력
output "instance_public_ip" {
  value       = aws_instance.k3s_server.public_ip
  description = "The public IP of the EC2 instance"
}