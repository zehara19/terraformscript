[
  {
    ...
    "environment": [
      ...
      {
        "name": "AWS_REGION",
        "value": "${region}"
      },
      {
        "name": "CELERY_BROKER_URL",
        "value": "sqs://${urlencode(sqs_access_key)}:${urlencode(sqs_secret_key)}@"
      },
      {
        "name": "CELERY_TASK_DEFAULT_QUEUE",
        "value": "${sqs_name}"
      }
    ],
    ...
  }
]
