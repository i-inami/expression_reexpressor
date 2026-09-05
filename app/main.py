from fastapi import FastAPI, HTTPException
from mangum import Mangum
from pydantic import BaseModel
from sympy import Eq, Symbol, solve, sstr
from sympy.parsing.sympy_parser import parse_expr

app = FastAPI()


class ReexpressRequest(BaseModel):
    expression: str
    variable: str


class ReexpressResponse(BaseModel):
    expressions: list[str]


@app.post("/reexpress", response_model=ReexpressResponse)
def reexpress(req: ReexpressRequest) -> ReexpressResponse:
    lhs_str, sep, rhs_str = req.expression.partition("=")
    try:
        equation = (
            Eq(parse_expr(lhs_str), parse_expr(rhs_str)) if sep else parse_expr(lhs_str)
        )
        solutions = solve(equation, Symbol(req.variable))
    except Exception as exc:
        raise HTTPException(
            status_code=400, detail=f"invalid expression: {exc}"
        ) from exc
    return ReexpressResponse(expressions=[sstr(s, order="none") for s in solutions])


handler = Mangum(app)
