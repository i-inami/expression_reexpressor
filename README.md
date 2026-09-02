# expression-reexpressor

## Run locally

```
uv run uvicorn app.main:app --reload &
```

## Invoke

```
curl -X POST localhost:8000/reexpress \
  -H 'content-type: application/json' \
  -d '{"expression":"y=a*x+b","variable":"x"}'
```
