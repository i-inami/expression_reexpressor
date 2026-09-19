import re

from fastapi import FastAPI, HTTPException
from mangum import Mangum
from pydantic import BaseModel, Field
from sympy import Basic, Eq, Symbol, solve, sstr
from sympy.parsing.sympy_parser import parse_expr

app = FastAPI()

# sympy's parse_expr evaluates via Python's eval() with no sandboxing (e.g.
# `__import__('os').system(...)` runs as-is), so incoming expressions are
# restricted to characters an algebraic equation can actually need. This also
# blocks `_`, closing the no-import-needed sandbox-escape pattern
# (`().__class__.__bases__[0].__subclasses__()`), which uses none of the
# characters excluded above.
_SAFE_EXPRESSION = re.compile(r"[A-Za-z0-9\s+\-*/().,=]+")


class ReexpressRequest(BaseModel):
    expressions: list[str]
    variable: str
    required: list[str] = Field(default_factory=list)


class ReexpressResponse(BaseModel):
    expressions: list[str]


def _parse_equation(expression: str):
    if not _SAFE_EXPRESSION.fullmatch(expression):
        raise ValueError(f"unsupported characters in expression: {expression!r}")
    lhs_str, sep, rhs_str = expression.partition("=")
    if sep:
        return Eq(parse_expr(lhs_str), parse_expr(rhs_str))
    return Eq(parse_expr(lhs_str), 0)


def _solution_values(result, symbol: Symbol) -> list:
    if isinstance(result, dict):
        return [result[symbol]]
    return [item[0] if isinstance(item, tuple) else item for item in result]


def _substitute_required(
    expr: Basic, aux_equations: list[Eq], required: set[Symbol]
) -> Basic:
    """Eliminate free symbols not in `required` using other equations that
    don't reference the already-solved-for symbol, until no more progress
    can be made (remaining symbols are treated as known constants)."""
    if not required:
        return expr
    remaining = list(aux_equations)
    progressed = True
    while progressed:
        progressed = False
        for symbol in expr.free_symbols - required:
            for i, eq in enumerate(remaining):
                if symbol not in eq.free_symbols:
                    continue
                eq_solutions = solve(eq, symbol)
                if eq_solutions:
                    expr = expr.subs(symbol, eq_solutions[0])
                    remaining.pop(i)
                    progressed = True
                    break
            if progressed:
                break
    return expr


@app.post("/reexpress", response_model=ReexpressResponse)
def reexpress(req: ReexpressRequest) -> ReexpressResponse:
    symbol = Symbol(req.variable)
    required = {Symbol(v) for v in req.required}
    try:
        equations = [_parse_equation(e) for e in req.expressions]
        aux_equations = [
            eq
            for eq in equations
            if isinstance(eq, Eq) and symbol not in eq.free_symbols
        ]
        solutions = _solution_values(solve(equations, symbol), symbol)
        solutions = [
            _substitute_required(s, aux_equations, required) for s in solutions
        ]
    except Exception as exc:
        raise HTTPException(
            status_code=400, detail=f"invalid expression: {exc}"
        ) from exc
    return ReexpressResponse(expressions=[sstr(s, order="none") for s in solutions])


handler = Mangum(app)
