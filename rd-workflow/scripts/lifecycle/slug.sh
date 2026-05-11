#!/usr/bin/env bash
# Slug 정규화: lowercase 영숫자 + `-`. 비-ASCII 거부.

normalize_slug() {
  local input="$1"
  if [[ -z "$input" ]]; then echo "slug: empty input" >&2; return 1; fi
  # 비-ASCII 검출 (printf | grep 방식 — here-string은 BSD grep의 [^\x00-\x7F] 해석 문제로 사용 불가)
  # [^ -~]: space(0x20)~tilde(0x7E) 범위 밖이면 비-ASCII (탭은 tr로 변환되므로 guard 불필요)
  if printf "%s" "$input" | LC_ALL=C grep -q '[^ -~]'; then
    echo "slug: non-ASCII rejected (transliteration is out of scope; use ASCII-only short-title)" >&2
    return 1
  fi
  local s="$input"
  s="$(printf '%s\n' "$s" | tr '[:upper:]' '[:lower:]')"
  # 공백 / underscore / dot → -
  s="$(printf '%s\n' "$s" | tr ' \t_.' '----')"
  # 영숫자 + `-` 외 발견 시 거부
  if [[ "$s" =~ [^a-z0-9-] ]]; then
    echo "slug: invalid characters (only [a-z0-9-] allowed): [$s]" >&2
    return 1
  fi
  # 연속 dash 압축
  s="$(printf '%s\n' "$s" | sed -E 's/-+/-/g')"
  # 양끝 dash 제거
  s="${s#-}"; s="${s%-}"
  if [[ -z "$s" ]]; then echo "slug: empty after normalization" >&2; return 1; fi
  if [[ ${#s} -gt 60 ]]; then echo "slug: too long (>60): [$s]" >&2; return 1; fi
  echo "$s"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  normalize_slug "$@"
fi
