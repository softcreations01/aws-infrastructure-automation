#!/bin/bash

################################
# Author: Gwhiz
# Version: v1

# This script creates an AWS Lambda function, an S3 bucket, an IAM role, and an SNS topic, all interconnected to perform various tasks.

# Constants
CONFIG_FILE="aws_script_config.json"
LOG_FILE="aws_script.log"

# Function to log messages to a log file
log() {
  local log_message="$1"
  echo "$(date +"[%Y-%m-%d %H:%M:%S]") $log_message" >> "$LOG_FILE"
}

# Load configuration from a JSON file
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  echo "Configuration file '$CONFIG_FILE' not found."
  exit 1
fi

# Ensure required variables are set in the configuration file
if [ -z "$aws_region" ] || [ -z "$bucket_name" ] || [ -z "$lambda_func_name" ] || [ -z "$role_name" ] || [ -z "$email_address" ] || [ -z "$iam_user_name" ]; then
  echo "Incomplete configuration. Please provide values for all required variables in '$CONFIG_FILE'."
  exit 1
fi

# Initialize log file
> "$LOG_FILE"

# Set AWS CLI profile (if necessary)
# export AWS_PROFILE="your_aws_profile"

# Check if the IAM role already exists
if ! aws iam get-role --role-name "$role_name" &> /dev/null; then
    # Role doesn't exist, create it
    role_response=$(aws iam create-role --role-name "$role_name" --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Action": "sts:AssumeRole",
        "Effect": "Allow",
        "Principal": {
          "Service": [
             "lambda.amazonaws.com",
             "s3.amazonaws.com",
             "sns.amazonaws.com"
          ]
        }
      }]
    }')

    # Extract the role ARN from the JSON response and store it in a variable
    role_arn=$(echo "$role_response" | jq -r '.Role.Arn')
else
    # Role already exists, no need to create it
    log "IAM role '$role_name' already exists."
    role_arn=$(aws iam get-role --role-name "$role_name" | jq -r '.Role.Arn')
fi

# Attach Permissions to the Role (no need to attach if role already exists)
if ! aws iam list-attached-role-policies --role-name "$role_name" | grep -q AWSLambda_FullAccess; then
    aws iam attach-role-policy --role-name "$role_name" --policy-arn arn:aws:iam::aws:policy/AWSLambda_FullAccess
fi

if ! aws iam list-attached-role-policies --role-name "$role_name" | grep -q AmazonSNSFullAccess; then
    aws iam attach-role-policy --role-name "$role_name" --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess
fi

# Create the S3 bucket and capture the output in a variable
bucket_output=$(aws s3api create-bucket --bucket "$bucket_name" --region "$aws_region")

# Upload a file to the bucket
aws s3 cp ./example_file.txt "s3://$bucket_name/example_file.txt"

# Create a Zip file to upload Lambda Function
zip -r s3-lambda-function.zip ./s3-lambda-function

# Get AWS account ID
aws_account_id=$(aws sts get-caller-identity --query 'Account' --output text)

# Construct the Lambda function ARN
lambda_function_arn="arn:aws:lambda:$aws_region:$aws_account_id:function:$lambda_func_name"

# Create a Lambda function
aws lambda create-function \
  --region "$aws_region" \
  --function-name "$lambda_func_name" \
  --runtime "python3.8" \
  --handler "s3-lambda-function/s3-lambda-function.lambda_handler" \
  --memory-size 128 \
  --timeout 30 \
  --role "$role_arn" \
  --zip-file "fileb://./s3-lambda-function.zip"

# Add Permissions to S3 Bucket to invoke Lambda
aws lambda add-permission \
  --function-name "$lambda_func_name" \
  --statement-id "${lambda_func_name}-invoke-permission" \
  --action "lambda:InvokeFunction" \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$bucket_name"

# Create an S3 event trigger for the Lambda function
aws s3api put-bucket-notification-configuration \
  --region "$aws_region" \
  --bucket "$bucket_name" \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [{
        "LambdaFunctionArn": "'"$lambda_function_arn"'",
        "Events": ["s3:ObjectCreated:*"]
    }]
}'

# Create an SNS topic and save the topic ARN to a variable
topic_arn=$(aws sns create-topic --name "$role_name" --output json | jq -r '.TopicArn')

# Print the TopicArn
log "SNS Topic ARN: $topic_arn"

# Create an IAM policy JSON file with the required permissions (e.g., publish to SNS)
# Create an IAM policy JSON file with the required permissions (e.g., publish to SNS)
cat > sns-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sns:Publish"
      ],
      "Resource": "$topic_arn"  # Use the ARN of the SNS topic
    }
  ],
  "Principal": {
    "Service": "sns.amazonaws.com"
  }
}
EOF

# Create the IAM policy
aws iam create-policy \
  --policy-name SNSPublishPolicy \
  --policy-document file://sns-policy.json

# Attach the policy to the IAM user
aws iam attach-user-policy \
  --user-name "$iam_user_name" \
  --policy-arn "arn:aws:iam::928951587112:policy/SNSPublishPolicy"

log "Script execution completed successfully."
