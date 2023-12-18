import logging
import time

from django_aws import celery


@celery.app.task()
def web_task() -> None:
    logging.info("Starting web task...")
    time.sleep(10)
    logging.info("Done web task.")
