CELERY_BROKER_URL = env("CELERY_BROKER_URL", default="sqs://localhost:9324")
CELERY_TASK_DEFAULT_QUEUE = env("CELERY_TASK_DEFAULT_QUEUE", default="default")
CELERY_BROKER_TRANSPORT_OPTIONS = {
    "region": env("AWS_REGION", default="us-east-1")
}
from datetime import timedelta
...
CELERY_BEAT_SCHEDULE = {
    "beat_task": {
        "task": "django_aws.tasks.beat_task",
        "schedule": timedelta(minutes=1),
    },
}
