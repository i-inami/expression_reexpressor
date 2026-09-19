import ast
import operator

from fastapi import FastAPI, HTTPException
from mangum import Mangum
from pydantic import BaseModel, Field
from sympy import (
    Basic,
    Eq,
    Number,
    Symbol,
    acos,
    asin,
    atan,
    cos,
    exp,
    factorial,
    log,
    sin,
    solve,
    sqrt,
    sstr,
    tan,
)

app = FastAPI()

# sympy's parse_expr evaluates via Python's eval() with no sandboxing, and no
# combination of global_dict/character-allowlist closes it off completely
# (e.g. `().__class__.__bases__[0].__subclasses__()` needs no name lookup at
# all). Instead, expressions are parsed with Python's own `ast` module
# (syntax only, nothing is executed) and walked by hand below, translating
# only an explicit allowlist of node shapes into sympy calls. Anything else
# -- a call to a name not in _ALLOWED_CALLS, attribute/subscript access,
# string/import/etc. -- falls through to the final raise.
_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.Pow: operator.pow,
}
_UNARY_OPS = {
    ast.USub: operator.neg,
    ast.UAdd: operator.pos,
}
_ALLOWED_CALLS = {
    "factorial": factorial,
    "sqrt": sqrt,
    "exp": exp,
    "log": log,
    "sin": sin,
    "cos": cos,
    "tan": tan,
    "asin": asin,
    "acos": acos,
    "atan": atan,
}


def _safe_eval(node: ast.AST):
    if isinstance(node, ast.Expression):
        return _safe_eval(node.body)
    if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
        return _BIN_OPS[type(node.op)](_safe_eval(node.left), _safe_eval(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
        return _UNARY_OPS[type(node.op)](_safe_eval(node.operand))
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return Number(node.value)
    if isinstance(node, ast.Name):
        return Symbol(node.id)
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id in _ALLOWED_CALLS
        and not node.keywords
    ):
        return _ALLOWED_CALLS[node.func.id](*(_safe_eval(a) for a in node.args))
    raise ValueError(f"unsupported syntax: {ast.dump(node)}")


def _parse_expr(expression: str) -> Basic:
    return _safe_eval(ast.parse(expression, mode="eval"))


class ReexpressRequest(BaseModel):
    expressions: list[str]
    variable: str
    required: list[str] = Field(default_factory=list)


class ReexpressResponse(BaseModel):
    expressions: list[str]


def _parse_equation(expression: str):
    lhs_str, sep, rhs_str = expression.partition("=")
    if sep:
        return Eq(_parse_expr(lhs_str), _parse_expr(rhs_str))
    return Eq(_parse_expr(lhs_str), 0)


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
