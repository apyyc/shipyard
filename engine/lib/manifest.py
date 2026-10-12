#!/usr/bin/env python3
"""shipyard 领域层：清单解析与严格校验。

用法:
    python3 engine/lib/manifest.py <manifest.json> <env> [--config engine/config.json]

输出 shell 可 eval 的 CFG_* / ENGINE_* 变量；校验失败以非 0 退出。
"""

import json
import os
import shlex
import sys

DEFAULTS = {
    "ssh_timeout": 15,
    "rsync_bwlimit": 0,
    "health_retries": 30,
    "health_interval": 2,
    "log_dir": "logs",
}


def die(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    if len(argv) < 3:
        die("用法: manifest.py <manifest.json> <env> [--config engine/config.json]")
    manifest_path, env = argv[1], argv[2]
    config_path = None
    if "--config" in argv:
        try:
            config_path = argv[argv.index("--config") + 1]
        except IndexError:
            die("--config 缺少文件路径")
    return manifest_path, env, config_path


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as exc:
        die(f"{what}解析失败 {path}: {exc}")


def check(cond, msg, errors):
    if not cond:
        errors.append(msg)


def normalize_remote(value, where):
    if isinstance(value, str):
        value = value.strip()
        if value.count(":") < 2 or "@" not in value:
            raise ValueError(f"{where}.remote 字符串格式应为 user@host:port:dir")
        return value
    if isinstance(value, dict):
        user = str(value.get("user") or "")
        host = str(value.get("host") or "")
        port = str(value.get("port") or "")
        directory = str(value.get("dir") or "")
        if not user or not host or not port or not directory:
            raise ValueError(f"{where}.remote 对象缺少 user/host/port/dir")
        return f"{user}@{host}:{port}:{directory}"
    raise ValueError(f"{where}.remote 必须是字符串或对象")


def validate(manifest, env):
    errors = []
    if not isinstance(manifest, dict):
        die("清单根节点必须是 JSON 对象")

    check(manifest.get("project"), "清单缺少 project", errors)
    check(manifest.get("app_dir"), "清单缺少 app_dir", errors)

    envs = manifest.get("environments")
    if not isinstance(envs, dict) or not envs:
        errors.append("environments 至少需要一个环境")
        envs = {}

    for step, key in (("test", "cmd"), ("build", "script"), ("upload", "source_dir")):
        section = manifest.get(step) or {}
        if not isinstance(section, dict):
            errors.append(f"{step} 必须是对象")
            continue
        if section.get("enabled"):
            check(section.get(key), f"{step} 启用时缺少 {key}", errors)
            if step == "build":
                tag_source = section.get("tag_source")
                if tag_source:
                    check(isinstance(tag_source, dict), "build.tag_source 必须是对象", errors)
                    if isinstance(tag_source, dict):
                        check(tag_source.get("file"), "build.tag_source 缺少 file", errors)
                        check(tag_source.get("pattern"), "build.tag_source 缺少 pattern", errors)

    selected = None
    if env not in envs:
        errors.append(f"清单里没有环境 {env}（可用: {', '.join(envs) or '无'}）")
    else:
        selected = envs[env]
        if not isinstance(selected, dict):
            errors.append(f"environments.{env} 必须是对象")
            selected = None
        else:
            if not selected.get("enabled"):
                errors.append(f"环境 {env} 未启用（enabled=false）")
            try:
                normalized = normalize_remote(selected.get("remote"), f"environments.{env}")
                selected["_remote_normalized"] = normalized
            except ValueError as exc:
                errors.append(str(exc))
            health = selected.get("health_url")
            if health is not None and not isinstance(health, str):
                errors.append(f"environments.{env}.health_url 必须是字符串")
            ssh_key = selected.get("ssh_key")
            if ssh_key is not None and not isinstance(ssh_key, str):
                errors.append(f"environments.{env}.ssh_key 必须是字符串")
            deploy_cmd = selected.get("deploy_cmd")
            if deploy_cmd is not None and not isinstance(deploy_cmd, str):
                errors.append(f"environments.{env}.deploy_cmd 必须是字符串")

    if errors:
        die("清单校验失败:\n  - " + "\n  - ".join(errors))
    return selected or {}


def main():
    manifest_path, env, config_path = parse_args(sys.argv)
    manifest = load_json(manifest_path, "清单")
    cfg = dict(DEFAULTS)
    if config_path and os.path.exists(config_path):
        file_cfg = load_json(config_path, "引擎配置")
        if isinstance(file_cfg, dict):
            cfg.update({k: v for k, v in file_cfg.items() if k in DEFAULTS})
    env_cfg = validate(manifest, env)

    out = []

    def emit(key, value):
        out.append(f"CFG_{key}={shlex.quote(str(value))}")

    def emit_cfg(key, value):
        out.append(f"ENGINE_{key}={shlex.quote(str(value))}")

    emit("PROJECT", manifest["project"])
    emit("TITLE", manifest.get("title", manifest["project"]))
    emit("REPO", manifest.get("repo", ""))
    emit("REPO_ROOT", manifest.get("repo_root", ""))
    emit("SCHEMA_VERSION", manifest.get("schema_version", "1.0"))
    emit("APP_DIR", manifest["app_dir"])

    test_cfg = manifest.get("test") or {}
    emit("TEST_ENABLED", bool(test_cfg.get("enabled")))
    emit("TEST_CMD", test_cfg.get("cmd", ""))

    build_cfg = manifest.get("build") or {}
    emit("BUILD_ENABLED", bool(build_cfg.get("enabled")))
    emit("BUILD_SCRIPT", build_cfg.get("script", ""))
    emit("BUILD_ARGS", " ".join(str(x) for x in (build_cfg.get("args") or [])))
    emit("BUILD_TAG_ARG", build_cfg.get("tag_arg", "--tag"))
    tag_source = build_cfg.get("tag_source") or {}
    emit("TAG_FILE", tag_source.get("file", ""))
    emit("TAG_PATTERN", tag_source.get("pattern", ""))

    upload_cfg = manifest.get("upload") or {}
    emit("UPLOAD_ENABLED", bool(upload_cfg.get("enabled")))
    emit("UPLOAD_SOURCE", upload_cfg.get("source_dir", ""))
    emit("UPLOAD_ARGS", " ".join(str(x) for x in (upload_cfg.get("args") or [])))
    emit("UPLOAD_EXCLUDE", " ".join(str(x) for x in (upload_cfg.get("exclude") or [])))

    emit("ENV_NAME", env)
    emit("ENV_REMOTE", env_cfg.get("_remote_normalized", env_cfg.get("remote", "")))
    emit("ENV_HEALTH", env_cfg.get("health_url", ""))
    emit("ENV_DEPLOY_CMD", env_cfg.get("deploy_cmd", ""))
    emit("ENV_SSH_KEY", env_cfg.get("ssh_key", ""))

    for key, value in cfg.items():
        emit_cfg(key, value)

    print("\n".join(out))


if __name__ == "__main__":
    main()
