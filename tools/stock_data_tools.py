"""
Stock Data Tools — ai2alpha.cn 股票数据查询工具集

从 ai2alpha 股票数据服务查询股市数据。
所有工具只读，通过 HTTPS 调用 stock_data 后端的 Agent 专用端点。

依赖环境变量：
  STOCK_DATA_BASE_URL  — 服务地址，默认 https://ai2alpha.cn
  STOCK_DATA_API_KEY   — 服务账号 Bearer Token（必填）
"""

import json
import logging
import os

import httpx

from tools.registry import registry

logger = logging.getLogger(__name__)

_BASE_URL = os.getenv("STOCK_DATA_BASE_URL", "https://ai2alpha.cn")
_TIMEOUT = 10.0


def _headers() -> dict:
    """构建鉴权请求头，未配置 KEY 时抛出异常。"""
    key = os.getenv("STOCK_DATA_API_KEY", "")
    if not key:
        raise EnvironmentError("STOCK_DATA_API_KEY 未配置，无法调用 stock_data 服务")
    return {"Authorization": f"Bearer {key}"}


def _check_stock_data_key() -> bool:
    """工具可用性检查：STOCK_DATA_API_KEY 是否已配置。"""
    return bool(os.getenv("STOCK_DATA_API_KEY"))


# ─────────────────────────────────────────────────────────────────────────────
# stock_search
# ─────────────────────────────────────────────────────────────────────────────

def stock_search_tool(query: str, stock_type: str = None, limit: int = 10) -> str:
    """
    按股票代码或公司名称搜索股票。
    返回 JSON 字符串，包含匹配的股票列表。
    """
    query = (query or "").strip()
    if not query:
        return json.dumps(
            {"success": False, "error": "query 不能为空，请提供股票代码或公司名称"},
            ensure_ascii=False,
        )

    if stock_type and stock_type.upper() not in {"A", "HK", "USA"}:
        return json.dumps(
            {"success": False, "error": "stock_type 无效，支持的值：A、HK、USA"},
            ensure_ascii=False,
        )

    limit = max(1, min(limit, 50))

    params = {"query": query, "limit": limit}
    if stock_type:
        params["stock_type"] = stock_type.upper()

    try:
        with httpx.Client(timeout=_TIMEOUT) as client:
            resp = client.get(
                f"{_BASE_URL}/api/v1/agent/stocks/search",
                params=params,
                headers=_headers(),
            )

        if resp.status_code == 401:
            return json.dumps(
                {"success": False, "error": "鉴权失败，请检查服务器 STOCK_DATA_API_KEY 配置"},
                ensure_ascii=False,
            )
        if resp.status_code != 200:
            return json.dumps(
                {"success": False, "error": f"服务请求失败 (HTTP {resp.status_code})"},
                ensure_ascii=False,
            )

        data = resp.json()
        return json.dumps(
            {
                "success": True,
                "query": data.get("query"),
                "total": data.get("total", 0),
                "items": data.get("items", []),
            },
            ensure_ascii=False,
            indent=2,
        )

    except httpx.TimeoutException:
        return json.dumps(
            {"success": False, "error": "请求超时，请稍后重试"},
            ensure_ascii=False,
        )
    except EnvironmentError as e:
        return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)
    except Exception as e:
        logger.error("stock_search_tool error: %s", e)
        return json.dumps(
            {"success": False, "error": f"工具执行失败: {e}"},
            ensure_ascii=False,
        )


_STOCK_SEARCH_SCHEMA = {
    "name": "stock_search",
    "description": (
        "按股票代码或公司名称搜索股票，返回匹配的股票列表（代码、名称、市场、行业、当前价格）。"
        "用于将用户提到的公司名称转换为精确的股票代码，再供其他股票工具使用。"
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": (
                    "搜索关键词，支持股票代码（如 '600519'、'00700.HK'、'AAPL'）"
                    "或公司名称（如 '贵州茅台'、'腾讯'、'Apple'）"
                ),
            },
            "stock_type": {
                "type": "string",
                "description": "市场过滤，可选值：A（A股）、HK（港股）、USA（美股）。不传则搜索全市场",
            },
            "limit": {
                "type": "integer",
                "description": "最多返回多少条结果，默认10，最多50",
            },
        },
        "required": ["query"],
    },
}

registry.register(
    name="stock_search",
    toolset="stock_data",
    schema=_STOCK_SEARCH_SCHEMA,
    handler=lambda args, **kw: stock_search_tool(
        query=args.get("query", ""),
        stock_type=args.get("stock_type"),
        limit=args.get("limit", 10),
    ),
    check_fn=_check_stock_data_key,
    requires_env=["STOCK_DATA_API_KEY"],
    emoji="🔍",
    max_result_size_chars=20_000,
)
