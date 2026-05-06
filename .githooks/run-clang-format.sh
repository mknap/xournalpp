#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

have_clang_format=0
if command -v clang-format >/dev/null 2>&1; then
    have_clang_format=1
fi

have_python3=0
if command -v python3 >/dev/null 2>&1; then
    have_python3=1
fi

LUA_DEF_INPUTS=(
    "src/core/plugin/luapi_application.h"
    "scripts/lua_def_file.py"
    "src/core/enums/generated/Action.NameMap.generated.h"
    "src/core/control/ToolEnums.h"
    "src/core/control/tools/EditSelection.h"
)

lua_def_needs_regen_from_list() {
    local file_list="$1"
    local f input

    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        for input in "${LUA_DEF_INPUTS[@]}"; do
            if [ "${f}" = "${input}" ]; then
                return 0
            fi
        done
    done <"${file_list}"

    return 1
}

run_lua_def_regen() {
    if [ "${have_python3}" -ne 1 ]; then
        echo "python3 not found; skipping lua_def_file.py check"
        return 1
    fi

    python3 scripts/lua_def_file.py
    return 0
}

is_cpp_file() {
    case "$1" in
        *.c|*.cc|*.cpp|*.cxx|*.h|*.hh|*.hpp|*.hxx) return 0 ;;
        *) return 1 ;;
    esac
}

collect_files_pre_commit() {
    git diff --cached --name-only --diff-filter=ACMR
}

collect_files_pre_push() {
    local remote_name="$1"
    local refs_file="$2"
    local local_ref local_sha remote_ref remote_sha

    while read -r local_ref local_sha remote_ref remote_sha; do
        [ -z "${local_ref}" ] && continue
        [ -z "${local_sha}" ] && continue

        if [ "${remote_sha}" = "0000000000000000000000000000000000000000" ]; then
            local base=""
            if git show-ref --quiet refs/remotes/${remote_name}/master; then
                base="$(git merge-base "${local_sha}" "refs/remotes/${remote_name}/master")"
            elif git show-ref --quiet refs/remotes/origin/master; then
                base="$(git merge-base "${local_sha}" "refs/remotes/origin/master")"
            elif git show-ref --quiet refs/heads/master; then
                base="$(git merge-base "${local_sha}" "refs/heads/master")"
            fi

            if [ -n "${base}" ]; then
                git diff --name-only --diff-filter=ACMR "${base}" "${local_sha}"
            else
                git diff-tree --no-commit-id --name-only -r --diff-filter=ACMR "${local_sha}"
            fi
        else
            git diff --name-only --diff-filter=ACMR "${remote_sha}" "${local_sha}"
        fi
    done <"${refs_file}"
}

format_files() {
    if [ "${have_clang_format}" -ne 1 ]; then
        return 1
    fi

    local changed=0
    local before_hash after_hash
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        [ -f "${f}" ] || continue
        if is_cpp_file "${f}"; then
            before_hash="$(sha256sum "${f}" | awk '{print $1}')"
            clang-format -i "${f}"
            after_hash="$(sha256sum "${f}" | awk '{print $1}')"
            if [ "${before_hash}" != "${after_hash}" ]; then
                changed=1
                echo "formatted: ${f}"
            fi
        fi
    done

    if [ "${changed}" -eq 1 ]; then
        return 0
    fi

    return 1
}

if [ "${mode}" = "pre-commit" ]; then
    tmpfile="$(mktemp)"
    collect_files_pre_commit | sort -u >"${tmpfile}"

    if format_files <"${tmpfile}"; then
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            [ -f "${f}" ] || continue
            if is_cpp_file "${f}"; then
                git add "${f}"
            fi
        done <"${tmpfile}"
        echo "clang-format applied to staged C/C++ files"
    fi

    if lua_def_needs_regen_from_list "${tmpfile}"; then
        if run_lua_def_regen; then
            if ! git diff --quiet -- plugins/luapi_application.def.lua; then
                git add plugins/luapi_application.def.lua
                echo "regenerated: plugins/luapi_application.def.lua"
            fi
        fi
    fi

    rm -f "${tmpfile}"
    exit 0
fi

if [ "${mode}" = "pre-push" ]; then
    remote_name="${2:-origin}"
    refs_file="${3:-}"

    if [ -z "${refs_file}" ] || [ ! -f "${refs_file}" ]; then
        exit 0
    fi

    tmpfile="$(mktemp)"
    collect_files_pre_push "${remote_name}" "${refs_file}" | sort -u >"${tmpfile}"

    if format_files <"${tmpfile}"; then
        rm -f "${tmpfile}"
        echo "clang-format changed files before push. Commit formatting changes, then push again."
        exit 1
    fi

    if lua_def_needs_regen_from_list "${tmpfile}"; then
        if run_lua_def_regen; then
            if ! git diff --quiet -- plugins/luapi_application.def.lua; then
                rm -f "${tmpfile}"
                echo "lua_def_file.py changed plugins/luapi_application.def.lua before push. Commit regenerated file, then push again."
                exit 1
            fi
        fi
    fi

    rm -f "${tmpfile}"
    exit 0
fi

echo "usage: $0 pre-commit | pre-push <remote> <refs-file>"
exit 2