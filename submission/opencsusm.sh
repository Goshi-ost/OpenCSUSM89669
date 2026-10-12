#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  export MSYS2_ARG_CONV_EXCL='*'
fi

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"
# I went with the GPU lane. vLLM needs CUDA, and g4dn.xlarge has a T4 and 4 vCPUs,
# which is exactly my approved quota. Stage 1 checks the quota and live price first.
INSTANCE_TYPE="g4dn.xlarge"
# Smallest Qwen model, so it fits easily on the T4 and downloads quickly.
MODEL="Qwen/Qwen2.5-0.5B-Instruct"
PROJECT_TAG="opencsusm"
KEY_NAME="opencsusm-key"
SG_NAME="opencsusm-ssh-only"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="$ROOT_DIR/$KEY_NAME.pem"
STATE_FILE="$ROOT_DIR/.opencsusm-state"
AMI_PARAMETER="/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"

usage() {
  printf 'Usage: %s 1|2|3|4|5|6|7|8\n' "$0" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

require_aws() {
  command -v aws >/dev/null || { echo "AWS CLI is required." >&2; exit 1; }
}

load_state() {
  [[ -f "$STATE_FILE" ]] || {
    echo "No deployment state found; run stage 2 first." >&2
    exit 1
  }
  read -r INSTANCE_ID SG_ID KEY_NAME < "$STATE_FILE"
}

get_instance_host() {
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

wait_for_ssh() {
  local host="$1"
  local attempt
  printf 'Waiting for SSH at %s' "$host"
  for attempt in $(seq 1 60); do
    if ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=5 "ubuntu@$host" true 2>/dev/null; then
      printf '\nSSH is ready.\n'
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      printf '\nStill waiting (%s/60; about %s seconds elapsed)...' "$attempt" "$((attempt * 10))"
    fi
    sleep 10
  done
  printf '\nSSH did not become available; check the instance and your SSH ingress rule.\n' >&2
  return 1
}

case "$1" in
  1)
    require_aws
    command -v python3 >/dev/null || { echo "Python 3 is required to parse live AWS pricing." >&2; exit 1; }

    QUOTA="$(aws service-quotas get-service-quota --service-code ec2 \
      --quota-code L-DB2E81BA \
      --query 'Quota.Value' --output text)"
    QUOTA_WHOLE="${QUOTA%%.*}"
    if [[ ! "$QUOTA_WHOLE" =~ ^[0-9]+$ ]] || (( QUOTA_WHOLE < 4 )); then
      printf 'Running On-Demand G/VT quota: %s vCPUs; %s requires 4. Do not launch.\n' \
        "$QUOTA" "$INSTANCE_TYPE" >&2
      exit 1
    fi
    printf 'Running On-Demand G/VT quota: %s vCPUs (%s requires 4).\n' "$QUOTA" "$INSTANCE_TYPE"

    PRICE_JSON="$(aws pricing get-products --service-code AmazonEC2 \
      --filters "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE_TYPE" \
        'Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)' \
        'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
        'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
        'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
        'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
      --query 'PriceList[0]' --output text)"
    HOURLY_PRICE="$(printf '%s' "$PRICE_JSON" | python3 -c '
import json, sys
product = json.load(sys.stdin)
prices = [
    dimension["pricePerUnit"]["USD"]
    for term in product["terms"]["OnDemand"].values()
    for dimension in term["priceDimensions"].values()
    if dimension["unit"] == "Hrs"
]
if not prices:
    raise SystemExit("No hourly On-Demand price found for this instance.")
print(prices[0])
')"
    python3 -c 'from decimal import Decimal; import sys; price=Decimal(sys.argv[1]); print(f"Live On-Demand price: ${price}/hour; 4 hours: ${price * 4:.2f} (storage and transfer extra).")' "$HOURLY_PRICE"
    ;;
  2)
    require_aws
    if [[ -f "$STATE_FILE" ]]; then
      load_state
      SSH_HOST="$(get_instance_host)"
      printf 'Reusing existing instance %s at %s. No new instance created.\n' "$INSTANCE_ID" "$SSH_HOST"
    else
      command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
      MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '\r\n')"
      [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
        echo "Could not determine your public IPv4 address." >&2
        exit 1
      }
      VPC_ID="$(aws ec2 describe-vpcs \
        --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
      [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || {
        echo "No default VPC found in $REGION." >&2
        exit 1
      }
      AMI_ID="$(aws ssm get-parameter --name "$AMI_PARAMETER" \
        --query 'Parameter.Value' --output text)"
      umask 077
      aws ec2 create-key-pair --key-name "$KEY_NAME" \
        --query KeyMaterial --output text > "$KEY_FILE"
      SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description 'SSH from my IP only, model is reached through a tunnel' \
        --vpc-id "$VPC_ID" --query GroupId --output text)"
      aws ec2 create-tags --resources "$SG_ID" \
        --tags "Key=Project,Value=$PROJECT_TAG" "Key=Name,Value=$SG_NAME"
      aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null
      INSTANCE_ID="$(aws ec2 run-instances --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=80,VolumeType=gp3}' \
        --tag-specifications \
          "ResourceType=instance,Tags=[{Key=Name,Value=opencsusm-vllm},{Key=Project,Value=$PROJECT_TAG}]" \
          "ResourceType=volume,Tags=[{Key=Name,Value=opencsusm-vllm-root},{Key=Project,Value=$PROJECT_TAG}]" \
        --query 'Instances[0].InstanceId' --output text)"
      printf '%s %s %s\n' "$INSTANCE_ID" "$SG_ID" "$KEY_NAME" > "$STATE_FILE"
      chmod 600 "$STATE_FILE"
      aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
      SSH_HOST="$(get_instance_host)"
      printf 'Launched %s (%s).\n' "$INSTANCE_ID" "$SSH_HOST"
    fi
    printf 'SSH: ssh -i "%s" ubuntu@%s\n' "$KEY_FILE" "$SSH_HOST"
    ;;
  3)
    require_aws
    load_state
    SSH_HOST="$(get_instance_host)"
    wait_for_ssh "$SSH_HOST"
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new "ubuntu@$SSH_HOST" 'sudo bash -s' <<'REMOTE_INSTALL'
set -euo pipefail
systemctl stop vllm 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-venv python3-pip curl
python3 -m venv /opt/vllm
/opt/vllm/bin/pip install -U pip
cat > /opt/vllm-constraints.txt <<'EOF'
transformers==4.46.3
huggingface-hub==0.26.2
tokenizers==0.20.3
EOF
/opt/vllm/bin/pip install -c /opt/vllm-constraints.txt 'vllm==0.6.6.post1'
HF_HOME=/root/.cache/huggingface /opt/vllm/bin/python -c \
  "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen2.5-0.5B-Instruct')"
cat > /etc/systemd/system/vllm.service <<'EOF'
[Unit]
Description=vLLM OpenAI-compatible server
After=network-online.target

[Service]
Environment=VLLM_USE_V1=0
Environment=HF_HOME=/root/.cache/huggingface
ExecStart=/opt/vllm/bin/vllm serve Qwen/Qwen2.5-0.5B-Instruct --dtype half --max-model-len 2048 --gpu-memory-utilization 0.90 --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vllm
echo 'Stage 3 install complete.'
REMOTE_INSTALL
    ;;
  4)
    require_aws
    load_state
    SSH_HOST="$(get_instance_host)"
    wait_for_ssh "$SSH_HOST"
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new "ubuntu@$SSH_HOST" 'sudo bash -s' <<'REMOTE_SERVE'
set -euo pipefail
systemctl start vllm
for attempt in $(seq 1 180); do
  if journalctl -u vllm --no-pager -n 1000 | grep -Fq 'Application startup complete'; then
    curl -fsS http://127.0.0.1:8000/health >/dev/null
    echo 'startup complete'
    exit 0
  fi
  if systemctl is-failed --quiet vllm; then
    journalctl -u vllm --no-pager -n 100
    exit 1
  fi
  sleep 5
done
journalctl -u vllm --no-pager -n 100
echo 'Timed out waiting for startup complete.' >&2
exit 1
REMOTE_SERVE
    ;;
  5)
    require_aws
    load_state
    SSH_HOST="$(get_instance_host)"
    printf 'In a second terminal, run this and leave it running:\nssh -i "%s" -o StrictHostKeyChecking=accept-new -N -L 8000:localhost:8000 ubuntu@%s\n' \
      "$KEY_FILE" "$SSH_HOST"
    ;;
  6)
    command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
    RESPONSE="$(curl -sS --fail http://localhost:8000/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"I am John"}],"max_tokens":20,"temperature":0}')"
    printf '%s\n' "$RESPONSE"
    ;;
  7)
    require_aws
    load_state
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    echo "Instance stopped. Compute is off; EBS storage continues to incur charges."
    ;;
  8)
    require_aws
    INSTANCE_ID=""
    SG_ID=""
    if [[ -f "$STATE_FILE" ]]; then
      read -r INSTANCE_ID SG_ID KEY_NAME < "$STATE_FILE"
    fi

    INSTANCE_IDS=()
    TAGGED_INSTANCES="$(aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text)"
    while IFS= read -r id; do
      [[ -n "$id" && "$id" != "None" ]] && INSTANCE_IDS+=("$id")
    done < <(printf '%s\n' "$TAGGED_INSTANCES" | tr '\t' '\n')
    if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
      INSTANCE_IDS+=("$INSTANCE_ID")
    fi

    VOLUME_IDS=()
    for id in "${INSTANCE_IDS[@]}"; do
      volumes="$(aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' --output text 2>/dev/null || true)"
      while IFS= read -r volume_id; do
        [[ -n "$volume_id" && "$volume_id" != "None" ]] && VOLUME_IDS+=("$volume_id")
      done < <(printf '%s\n' "$volumes" | tr '\t' '\n')
    done
    TAGGED_VOLUMES="$(aws ec2 describe-volumes \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
      --query 'Volumes[].VolumeId' --output text)"
    while IFS= read -r volume_id; do
      [[ -n "$volume_id" && "$volume_id" != "None" ]] && VOLUME_IDS+=("$volume_id")
    done < <(printf '%s\n' "$TAGGED_VOLUMES" | tr '\t' '\n')

    SG_IDS=()
    TAGGED_SGS="$(aws ec2 describe-security-groups \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
      --query 'SecurityGroups[].GroupId' --output text)"
    while IFS= read -r group_id; do
      [[ -n "$group_id" && "$group_id" != "None" ]] && SG_IDS+=("$group_id")
    done < <(printf '%s\n' "$TAGGED_SGS" | tr '\t' '\n')
    [[ -n "$SG_ID" && "$SG_ID" != "None" ]] && SG_IDS+=("$SG_ID")

    declare -A SEEN=()
    UNIQUE_INSTANCE_IDS=()
    for id in "${INSTANCE_IDS[@]}"; do
      [[ -n "${SEEN[$id]:-}" ]] || { SEEN[$id]=1; UNIQUE_INSTANCE_IDS+=("$id"); }
    done
    for id in "${UNIQUE_INSTANCE_IDS[@]}"; do
      aws ec2 terminate-instances --instance-ids "$id" >/dev/null
    done
    if ((${#UNIQUE_INSTANCE_IDS[@]} > 0)); then
      aws ec2 wait instance-terminated --instance-ids "${UNIQUE_INSTANCE_IDS[@]}"
    fi

    cleanup_failed=0
    SEEN=()
    UNIQUE_VOLUME_IDS=()
    for volume_id in "${VOLUME_IDS[@]}"; do
      [[ -n "${SEEN[$volume_id]:-}" ]] || { SEEN[$volume_id]=1; UNIQUE_VOLUME_IDS+=("$volume_id"); }
    done
    for volume_id in "${UNIQUE_VOLUME_IDS[@]}"; do
      volume_state="$(aws ec2 describe-volumes --volume-ids "$volume_id" \
        --query 'Volumes[0].State' --output text 2>/dev/null || true)"
      if [[ -z "$volume_state" || "$volume_state" == "None" ]]; then
        continue
      fi
      deleted=0
      for attempt in $(seq 1 12); do
        if aws ec2 delete-volume --volume-id "$volume_id" >/dev/null 2>&1; then
          deleted=1
          break
        fi
        volume_state="$(aws ec2 describe-volumes --volume-ids "$volume_id" \
          --query 'Volumes[0].State' --output text 2>/dev/null || true)"
        if [[ -z "$volume_state" || "$volume_state" == "None" ]]; then
          deleted=1
          break
        fi
        sleep 10
      done
      if (( deleted == 0 )); then
        printf 'Could not delete EBS volume after retries: %s\n' "$volume_id" >&2
        cleanup_failed=1
      fi
    done

    SEEN=()
    UNIQUE_SG_IDS=()
    for group_id in "${SG_IDS[@]}"; do
      [[ -n "${SEEN[$group_id]:-}" ]] || { SEEN[$group_id]=1; UNIQUE_SG_IDS+=("$group_id"); }
    done
    for group_id in "${UNIQUE_SG_IDS[@]}"; do
      deleted=0
      for attempt in $(seq 1 12); do
        if aws ec2 delete-security-group --group-id "$group_id" >/dev/null 2>&1; then
          deleted=1
          break
        fi
        sleep 10
      done
      if (( deleted == 0 )); then
        printf 'Could not delete security group after retries: %s\n' "$group_id" >&2
        cleanup_failed=1
      fi
    done

    if ! aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1; then
      printf 'Could not delete key pair: %s\n' "$KEY_NAME" >&2
      cleanup_failed=1
    fi

    REMAINING_INSTANCES="$(aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text)"
    REMAINING_VOLUMES="$(aws ec2 describe-volumes \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
      --query 'Volumes[].VolumeId' --output text)"
    REMAINING_SGS="$(aws ec2 describe-security-groups \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
      --query 'SecurityGroups[].GroupId' --output text)"
    INSTANCE_REPORT="$REMAINING_INSTANCES"
    VOLUME_REPORT="$REMAINING_VOLUMES"
    SG_REPORT="$REMAINING_SGS"
    [[ -z "$INSTANCE_REPORT" || "$INSTANCE_REPORT" == "None" ]] && INSTANCE_REPORT="none"
    [[ -z "$VOLUME_REPORT" || "$VOLUME_REPORT" == "None" ]] && VOLUME_REPORT="none"
    [[ -z "$SG_REPORT" || "$SG_REPORT" == "None" ]] && SG_REPORT="none"
    if [[ -n "$REMAINING_INSTANCES" && "$REMAINING_INSTANCES" != "None" ]] ||
      [[ -n "$REMAINING_VOLUMES" && "$REMAINING_VOLUMES" != "None" ]] ||
      [[ -n "$REMAINING_SGS" && "$REMAINING_SGS" != "None" ]]; then
      cleanup_failed=1
    fi
    if (( cleanup_failed == 0 )); then
      rm -f "$KEY_FILE" "$STATE_FILE"
    else
      printf 'Stage 8 cleanup check:\n'
      printf '  Instances: %s\n' "$INSTANCE_REPORT"
      printf '  EBS volumes: %s\n' "$VOLUME_REPORT"
      printf '  Security groups: %s\n' "$SG_REPORT"
      printf 'Cleanup incomplete; state and key files were retained for recovery.\n' >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac

# ---- results ----
# Stage 6 output ($ bash opencsusm.sh 6):
# {"id":"chatcmpl-caddb4996de54535a05dfd1ea5c0d35c","object":"chat.completion","created":1791774039,"model":"Qwen/Qwen2.5-0.5B-Instruct","choices":[{"index":0,"message":{"role":"assistant","content":"Hello John! It's nice to meet you. As a language model, I don't have personal","tool_calls":[]},"logprobs":null,"finish_reason":"length","stop_reason":null}],"usage":{"prompt_tokens":32,"total_tokens":52,"completion_tokens":20,"prompt_tokens_details":null},"prompt_logprobs":null}
# Stage 8 output ($ bash opencsusm.sh 8): (empty)
