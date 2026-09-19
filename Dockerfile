FROM public.ecr.aws/lambda/python:3.12

COPY pyproject.toml ${LAMBDA_TASK_ROOT}/pyproject.toml
COPY app ${LAMBDA_TASK_ROOT}/app

WORKDIR ${LAMBDA_TASK_ROOT}
RUN pip install --no-cache-dir .

CMD ["app.main.handler"]
