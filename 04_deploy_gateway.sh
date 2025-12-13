#!/bin/bash

# Configuration
FUNC_NAME=$1
STAGE_NAME="prod"
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Helper function for input
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

echo "--- Deploying API Gateway ---"

# 1. Get Lambda ARN
FUNC_NAME=$(get_input "Enter Lambda Function Name" "$FUNC_NAME")
LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNC_NAME" --query 'Configuration.FunctionArn' --output text)

if [ -z "$LAMBDA_ARN" ]; then
    echo "Error: Could not find Lambda function '$FUNC_NAME'."
    exit 1
fi

# 2. Create REST API
echo "Creating REST API..."
API_ID=$(aws apigateway create-rest-api \
    --name "${FUNC_NAME}-api" \
    --description "API for PDF Filling Lambda" \
    --query 'id' --output text)

# 3. Get Root Resource ID
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)

# 4. Create '/pdf' Resource
echo "Creating /pdf resource..."
RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$ROOT_ID" \
    --path-part "pdf" \
    --query 'id' --output text)

# 5. Create Method (POST) - Require API Key
echo "Creating POST method (API Key Required)..."
aws apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$RESOURCE_ID" \
    --http-method POST \
    --authorization-type "NONE" \
    --api-key-required > /dev/null

# 6. Setup Integration (Lambda Proxy)
echo "Linking Lambda..."
# Note: integration setup requires a specific URI format
URI_ARN="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

aws apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$RESOURCE_ID" \
    --http-method POST \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "$URI_ARN" > /dev/null

# 7. Grant Permission to API Gateway to Invoke Lambda
echo "Granting Invoke permissions..."
# Source ARN format: arn:aws:execute-api:region:account-id:api-id/stage/method/resource-path
SOURCE_ARN="arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/*"

aws lambda add-permission \
    --function-name "$FUNC_NAME" \
    --statement-id "apigateway-prod-${RANDOM}" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "$SOURCE_ARN" > /dev/null 2>&1 || echo "Permission might already exist."

# 8. Deploy API
echo "Deploying API to stage '$STAGE_NAME'..."
aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --stage-name "$STAGE_NAME" > /dev/null

# 9. Create Usage Plan
echo "Creating Usage Plan (Required for API Keys)..."
PLAN_ID=$(aws apigateway create-usage-plan \
    --name "${FUNC_NAME}-usage-plan" \
    --description "Standard plan for PDF API" \
    --query 'id' --output text)

# Link API Stage to Usage Plan
aws apigateway update-usage-plan \
    --usage-plan-id "$PLAN_ID" \
    --patch-operations op=add,path=/apiStages,value="${API_ID}:${STAGE_NAME}" > /dev/null

# Save details for the Key Manager script
echo "$PLAN_ID" > .last_usage_plan_id
echo "https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}/pdf" > .last_api_url

echo "--- Deployment Complete ---"
echo "API URL: https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}/pdf"
echo "Usage Plan ID: $PLAN_ID"
