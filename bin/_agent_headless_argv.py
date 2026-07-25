"""Общий хелпер сборки headless-argv для `claude -p` (V2.1 §3).

Используется run_event (bin/claude-agent-run) и bin/claude-agent-review.
Параметризован политикой прав: старый blacklist (`disallowed_tools`) ИЛИ
settings-файл + permission_mode (пояс прав из спеки). Порядок флагов
совпадает с прежним хардкодом в обоих местах - ревьюер обязан остаться
байт-в-байт (V2.1 §9/U3), поэтому позиция блока прав не меняется.
"""


def build_headless_argv(claude_bin, model=None, *, disallowed_tools=None,
                        settings_file=None, permission_mode="default"):
    cmd = [claude_bin, "-p", "--output-format", "json"]
    if settings_file:
        cmd += ["--settings", settings_file,
                "--setting-sources", "user",
                "--permission-mode", permission_mode]
    else:
        cmd += ["--disallowedTools", disallowed_tools]
    cmd += ["--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    if model:
        cmd += ["--model", model]
    return cmd
