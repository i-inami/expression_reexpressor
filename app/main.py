from fastapi import FastAPI
from mangum import Mangum
from pydantic import BaseModel

app = FastAPI()


class ReexpressRequest(BaseModel):
    expression: str
    variable: str


class ReexpressResponse(BaseModel):
    expression: str


@app.post("/reexpress", response_model=ReexpressResponse)
def reexpress(req: ReexpressRequest) -> ReexpressResponse:
    return ReexpressResponse(expression="(y - b)/a")


handler = Mangum(app)
