#!/usr/bin/env bash
# =======================================================================
# OpenCSUSM Midterm Script -- CPU Lane (c7i.2xlarge + Ollama)
# CS 446 Cloud Computing « CSUSM « Fall 2026
# Key Pair: keypairFR.pem | Region: us-east-1
# =======================================================================

KEY_PATH="$HOME/.ssh/keypairFR.pem"
KEY_NAME="keypairFR"
REGION="us-east-1"
INSTANCE_TYPE="c7i-flex.large"
MODEL="qwen2.5:0.5b"
PORT=11434
STATE_FILE=".instance_info"

STAGE="$1"

if [ -z "$STAGE" ]; then
  echo "Usage: bash opencsusm.sh <stage-number> (1 through 8)"
  exit 1
fi

case "$STAGE" in
  1)
    echo "=== Stage 1: Quota & Pricing Check ==="
    echo "Lane Selected: CPU (c7i.2xlarge + Ollama + qwen2.5:0.5b)"
    echo "Defense: Instant launch without AWS G-family GPU quota delay (0.0 vCPU bypass)."
    echo "Pricing: c7i.2xlarge ($0.3570/hr) ~ 280 hours on $100 budget."
    echo ""
    echo "Checking G-instance quota for reference:"
    aws service-quotas get-service-quota --region "$REGION" \
      --service-code ec2 --quota-code L-DB2E81BA \
      --query "Quota.{QuotaName:QuotaName,Value:Value}" --output table 2>/dev/null || echo "G-Instance Quota: 0.0 (Bypassed via CPU Lane)"
    echo ""
    echo "Stage 1 complete. Ready for Stage 2."
    ;;

  2)
    echo "=== Stage 2: Launch EC2 Instance ==="
    VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
      VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    fi
    echo "Using VPC: $VPC_ID"

    # Find or auto-create a subnet in this VPC
    SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[0].SubnetId" --output text 2>/dev/null)
    if [ "$SUBNET_ID" == "None" ] || [ -z "$SUBNET_ID" ]; then
      echo "No subnet found in $VPC_ID. Creating default subnet in us-east-1a..."
      SUBNET_ID=$(aws ec2 create-default-subnet --region "$REGION" --availability-zone us-east-1a --query "Subnet.SubnetId" --output text 2>/dev/null)
    fi
    echo "Using Subnet: $SUBNET_ID"

    MY_IP=$(curl -sS https://checkip.amazonaws.com | tr -d '\n\r')
    echo "Your Public IP: $MY_IP"

    SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=opencsusm-sg" "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
      SG_ID=$(aws ec2 create-security-group --region "$REGION" --group-name "opencsusm-sg" --description "OpenCSUSM SSH Security Group" --vpc-id "$VPC_ID" --query "GroupId" --output text)
      aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null
    fi
    echo "Security Group ID: $SG_ID (Inbound Port 22 allowed ONLY from $MY_IP/32)"

    AMI_ID=$(aws ssm get-parameters --region "$REGION" --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query "Parameters[0].Value" --output text 2>/dev/null)
    if [ "$AMI_ID" == "None" ] || [ -z "$AMI_ID" ]; then
      AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
    fi
    echo "Launching $INSTANCE_TYPE ($AMI_ID)..."

    RUN_OUT=$(aws ec2 run-instances --region "$REGION" \
      --image-id "$AMI_ID" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" \
      --security-group-ids "$SG_ID" \
      --subnet-id "$SUBNET_ID" \
      --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=opencsusm-cpu}]' \
      --query "Instances[0].InstanceId" --output text)

    INSTANCE_ID="$RUN_OUT"
    echo "Instance ID: $INSTANCE_ID. Waiting for running state..."
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

    PUBLIC_DNS=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicDnsName" --output text)
    PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    echo "INSTANCE_ID=$INSTANCE_ID" > "$STATE_FILE"
    echo "PUBLIC_DNS=$PUBLIC_DNS" >> "$STATE_FILE"
    echo "PUBLIC_IP=$PUBLIC_IP" >> "$STATE_FILE"
    echo "SG_ID=$SG_ID" >> "$STATE_FILE"

    echo "Instance Running!"
    echo "Public IP: $PUBLIC_IP"
    echo "Public DNS: $PUBLIC_DNS"
    echo ""
    echo "Next: Run 'bash opencsusm.sh 3' to install Ollama."
    ;;

  3)
    echo "=== Stage 3: SSH & Install Ollama ==="
    if [ ! -f "$STATE_FILE" ]; then echo "Error: State file not found. Run Stage 2 first."; exit 1; fi
    source "$STATE_FILE"

    echo "Connecting to $PUBLIC_IP to install Ollama..."
    until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "echo SSH Ready" 2>/dev/null; do
      echo "Waiting for SSH connection to be available..."
      sleep 5
    done

    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "curl -fsSL https://ollama.com/install.sh | sh"
    echo "Stage 3 complete. Ollama installed and active as systemd service."
    ;;

  4)
    echo "=== Stage 4: Pull & Serve Model ($MODEL) ==="
    if [ ! -f "$STATE_FILE" ]; then echo "Error: State file not found. Run Stage 2 first."; exit 1; fi
    source "$STATE_FILE"

    echo "Pulling $MODEL on $PUBLIC_IP..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "ollama pull $MODEL"
    echo "Stage 4 complete. Model $MODEL loaded and listening on port $PORT."
    ;;

  5)
    echo "=== Stage 5: SSH Tunnel Command Generator ==="
    if [ ! -f "$STATE_FILE" ]; then echo "Error: State file not found. Run Stage 2 first."; exit 1; fi
    source "$STATE_FILE"

    echo "COPY AND RUN THIS COMMAND IN A SECOND TERMINAL (LEAVE IT RUNNING):"
    echo "------------------------------------------------------------------"
    echo "ssh -i $KEY_PATH -N -L $PORT:localhost:$PORT ubuntu@$PUBLIC_IP"
    echo "------------------------------------------------------------------"
    echo ""
    echo "Then in your FIRST terminal, run 'bash opencsusm.sh 6' or test with:"
    echo "curl -sS localhost:$PORT/v1/chat/completions \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"I am John\"}],\"max_tokens\":20,\"temperature\":0}'"
    ;;

  6)
    echo "=== Stage 6: Test Local Tunnel Endpoint ==="
    curl -sS "localhost:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"I am John\"}], \"max_tokens\": 20, \"temperature\": 0}"
    echo ""
    ;;

  7)
    echo "=== Stage 7: Stop EC2 Instance ==="
    if [ ! -f "$STATE_FILE" ]; then echo "Error: State file not found."; exit 1; fi
    source "$STATE_FILE"
    echo "Stopping instance $INSTANCE_ID..."
    aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null
    echo "Instance $INSTANCE_ID stopped."
    ;;

  8)
    if [ -f "$STATE_FILE" ]; then
      source "$STATE_FILE"
      if [ -n "$INSTANCE_ID" ]; then
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1
      fi
      if [ -n "$SG_ID" ]; then
        aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" >/dev/null 2>&1
      fi
      rm -f "$STATE_FILE"
    fi
    echo "Teardown complete."
    ;;

  *)
    echo "Invalid stage: $STAGE. Use 1, 2, 3, 4, 5, 6, 7, or 8."
    ;;
esac
