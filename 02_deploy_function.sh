#!/bin/bash

FUNC_NAME=$1
BUCKET_NAME=$2
LAYER_ARN=$3
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Helper: Input Prompt
get_input() {
    local prompt_text=$1
    local var_value=$2
    if [ -z "$var_value" ]; then
        read -p "$prompt_text: " input
        echo "$input"
    else
        echo "$var_value"
    fi
}

# Helper: Wait for Lambda Update to Finish
wait_for_update() {
    local fname=$1
    echo "Waiting for update to finish..."
    while true; do
        STATUS=$(aws lambda get-function --function-name "$fname" --query 'Configuration.LastUpdateStatus' --output text)
        STATE=$(aws lambda get-function --function-name "$fname" --query 'Configuration.State' --output text)
        
        if [ "$STATUS" == "Successful" ] && [ "$STATE" == "Active" ]; then
            break
        elif [ "$STATUS" == "Failed" ]; then
            echo "Update failed."
            exit 1
        fi
        sleep 2
    done
}

echo "--- Deploying Lambda Function ---"

# 1. Gather Inputs
FUNC_NAME=$(get_input "Enter Function Name (e.g., pdf-filler)" "$FUNC_NAME")
BUCKET_NAME=$(get_input "Enter S3 Bucket Name for access" "$BUCKET_NAME")
ROLE_NAME="${FUNC_NAME}-role"

# Auto-detect layer
if [ -z "$LAYER_ARN" ] && [ -f ".last_layer_arn" ]; then
    DEFAULT_ARN=$(cat .last_layer_arn)
    read -p "Use Layer ARN from previous build ($DEFAULT_ARN)? [y/n]: " use_default
    if [ "$use_default" = "y" ]; then
        LAYER_ARN=$DEFAULT_ARN
    fi
fi
LAYER_ARN=$(get_input "Enter pypdf Layer ARN" "$LAYER_ARN")

# 2. Create IAM Role
echo "Checking/Creating IAM Role: $ROLE_NAME..."
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}'

aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" > /dev/null 2>&1
if [ $? -eq 0 ]; then echo "Role created."; else echo "Role likely exists. Proceeding..."; fi

# 3. Attach Permissions
echo "Attaching policies to $ROLE_NAME..."
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

S3_POLICY="{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        { \"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\", \"s3:PutObject\"], \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\" }
    ]
}"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name S3Access --policy-document "$S3_POLICY"

echo "Waiting for IAM propagation (5 seconds)..."
sleep 5

# 4. Zip Function
echo "Zipping function code..."
zip function.zip index.mjs package.json > /dev/null

# 5. Create or Update Lambda (With Wait Loop)
echo "Deploying Lambda function..."

# Check if function exists
aws lambda get-function --function-name "$FUNC_NAME" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "Function exists. Updating code..."
    aws lambda update-function-code --function-name "$FUNC_NAME" --zip-file fileb://function.zip > /dev/null
    
    # *** FIX: Wait for Code Update to finish before updating Config ***
    wait_for_update "$FUNC_NAME"

    echo "Updating configuration (Layer)..."
    aws lambda update-function-configuration \
        --function-name "$FUNC_NAME" \
        --layers "$LAYER_ARN" \
        --runtime nodejs24.x > /dev/null

    wait_for_update "$FUNC_NAME"
else
    echo "Creating new function..."
    ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    
    while true; do
        aws lambda create-function \
            --function-name "$FUNC_NAME" \
            --runtime nodejs24.x \
            --role "$ROLE_ARN" \
            --handler index.handler \
            --zip-file fileb://function.zip \
            --layers "$LAYER_ARN" \
            --timeout 30 \
            --memory-size 256 > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo "Function created successfully."
            break
        else
            echo "Role not ready yet. Retrying in 5 seconds..."
            sleep 5
        fi
    done
fi

echo "--- Deployment Complete ---"
echo "Function Name: $FUNC_NAME"
echo "Cleanup: rm function.zip .last_layer_arn"
