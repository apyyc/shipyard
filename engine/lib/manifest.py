#!/usr/bin/env python3
"""shipyard 领域层：清单解析与严格校验（纯逻辑，不执行任何操作）。

用法:
    python3 lib/manifest.py <manifest.json> <env> [--config engine/config.json]

输出 shell 可 eval 的 CFG_* / ENGINE_* 变量；校验失败以非 0 退出并打印错误。

职责边界:
    - 读清单、读引擎配置、合并默认值、严格校验
    - 不做任何 ssh/rsync/podman 等实际操作（那是应用层/基础设施层的事）
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


def parse_args(argv):
    if len(argv) < 3:
        sys.exit("❌ 用法: manifest.py <manifest.json> <env> [--config engine/config.json]")
    manifest_path, env = argv[1], argv[2]
    config_path = None
    if "--config" in argv:
        config_path = argv[argv.index("--config") + 1]
    return manifest_path, env, config_path


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        sys.exit(f"❌ {what}解析失败 {path}: {e}")


def check(obj, key, where):
    if not obj.get(key):
        raise ValueError(f"{where} 缺少字段 {key}")


def validate(manifest, env, manifest_path):
    errs = []
    try:
        check(manifest, "project", "清单")
        check(manifest, "app_dir", "清单")
    except ValueError as e:
        errs.append(str(e))
    if not isinstance(manifest.get("environments", {}), dict) or not manifest["environments"]:
        errs.append("environments 至少需要一个环境")

    for step, key in (("test", "cmd"), ("build", "script"), ("upload", "source_dir")):
        s = manifest.get(step) or {}
        if s.get("enabled"):
            try:
                check(s, key, step)
                if step == "build":
                    ts = s.get("tag_source")
                    if ts:
                        check(ts, "file", "build.tag_source")
                        check(ts, "pattern", "build.tag_source")
            except ValueError as e:
                errs.append(str(e))

    envs = manifest.get("environments", {})
    if env not in envs:
        errs.append(f"清单里没有环境 {env}（可用: {', '.join(envs) or '无'}）")
    else:
        e = envs[env]
        if not e.get("enabled"):
            errs.append(f"环境 {env} 未启用（enabled=false）")
        try:
            check(e, "remote", f"environments.{env}")
        except ValueError as ex:
            errs.append(str(ex))
        dc = e.get("deploy_cmd")
        if dc and not os.path.exists(os.path.join(os.path.dirname(manifest_path), "..", dc)):
            errs.append(f"deploy_cmd 文件不存在: {dc}")
    if errs:
        sys.exit("❌ 清单校验失败:\n  - " + "\n  - ".join(errs))
    return envs[env]


def main():
    manifest_path, env, config_path = parse_args(sys.argv)
    manifest = load_json(manifest_path, "清单")
    cfg = dict(DEFAULTS)
    if config_path and os.path.exists(config_path):
        file_cfg = load_json(config_path, "引擎配置")
        cfg.update({k: v for k, v in file_cfg.items() if k in DEFAULTS})
    env_cfg = validate(manifest, env, manifest_path)

    out = []

    def emit(k, v):
        out.append(f"CFG_{k}={shlex.quote(str(v))}")

    def emit_cfg(k, v):
        out.append(f"ENGINE_{k}={shlex.quote(str(v))}")

    emit("PROJECT", manifest["project"])
    emit("TITLE", manifest.get("title", manifest["project"]))
    emit("REPO", manifest.get("repo", ""))
    emit("SCHEMA_VERSION", manifest.get("schema_version", "1.0"))
    emit("APP_DIR", manifest["app_dir"])
    t = manifest.get("test", {})
    emit("TEST_ENABLED", t.get("enabled", False))
    emit("TEST_CMD", t.get("cmd", ""))
    b = manifest.get("build", {})
    emit("BUILD_ENABLED", b.get("enabled", False))
    emit("BUILD_SCRIPT", b.get("script", ""))
    emit("BUILD_ARGS", " ".join(b.get("args", [])))
    emit("BUILD_TAG_ARG", b.get("tag_arg", "--tag"))
    ts = b.get("tag_source") or {}
    emit("TAG_FILE", ts.get("file", ""))
    emit("TAG_PATTERN", ts.get("pattern", ""))
    u = manifest.get("upload", {})
    emit("UPLOAD_ENABLED", u.get("enabled", False))
    emit("UPLOAD_SOURCE", u.get("source_dir", ""))
    emit("ENV_NAME", env)
    emit("ENV_REMOTE", env_cfg.get("remote", ""))
    emit("ENV_HEALTH", env_cfg.get("health_url", ""))
    emit("ENV_DEPLOY_CMD", env_cfg.get("deploy_cmd", ""))
    emit("ENV_SSH_KEY", env_cfg.get("ssh_key", ""))

    for k, v in cfg.items():
        emit_cfg(k, v)

    print("\n".join(out))


if __name__ == "__main__":
    main()
